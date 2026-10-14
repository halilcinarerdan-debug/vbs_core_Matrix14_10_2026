Matrix.Kitchen = {}

-- ★ [M-3 FIX] Küsurat biriktirici: floor sonrası kalan gram kaybolmaz,
-- bir sonraki pişirimde birikir. 0-RNG (sadece toplama).
local _KitchenPartialGrams = {}

-- Hangi aktivite hangi beceriyi pratikle organik olarak büyütür (RNG yok).
local ACTIVITY_SKILL_MAP = {
    cooking        = 'skill_chemistry',
    distribution   = 'skill_logistics',
    cyber_ops      = 'skill_cyber',
    -- ★ KATMAN 7 FAZ 2: sokakta canlı NPC "keş" satışı, distribution İLE
    -- AYNI skill_logistics'i organik olarak büyütür -- yeni bir beceri
    -- alanı İCAT EDİLMEZ.
    street_dealing = 'skill_logistics'
}


-- FORMÜL (asimptotik/lojistik öğrenme eğrisi - "diminishing returns"):
--   skill' = skill + (1.0 - skill) * SkillGrowthRate
-- Yorum: bu, sürekli zamanda dS/dt = k*(1-S) diferansiyel denkleminin
-- ayrık (discrete, dt=1 dakika) Euler adımıdır; kapalı-form çözümü
-- S(t) = 1 - (1-S0)*e^(-k*t) olan klasik bir "doyum eğrisi"dir (RC devresi
-- şarjı veya Newton soğuma yasasıyla AYNI matematiksel aile). skill 1.0'a
-- ASLA ulaşmaz ama sonsuz yaklaşır -> tavan taşması riski yapısal olarak yok.
-- KARMAŞIKLIK: O(1).
local function ApplyOrganicSkillGrowth(bot)
    local skillKey = ACTIVITY_SKILL_MAP[bot.state.activity]
    if not skillKey then return end


    local current = bot.psychology[skillKey] or 0.0
    bot.psychology[skillKey] = Matrix.Clamp(
        current + ((1.0 - current) * Config.Kitchen.SkillGrowthRate),
        0.0, 1.0
    )
end




-- FORMÜL SETİ (her GERÇEK dakikada bir main.lua master ticker'ından çağrılır):
--   fatigue' = fatigue + workFactor*(2.0 - cognitive_shifter)   [birikimli, 0-1 clamp]
--   cortisol' = cortisol - base_recovery_rate*resilience         [her döngüde toparlanma]
--   cortisol' += FatigueCortisolBleed                            [SADECE fatigue>0.8 ise]
-- NÖRAL EROZYON (kalıcı hasar, OYNANABİLİRLİK KİLİDİ ile korunur): fatigue
-- kritik eşiği (0.9) GERÇEK 3600 saniye (1 saat) SÜREKLİ aşarsa -deterministik
-- bir zaman-damgası karşılaştırmasıyla, sayaç değil- resilience %10 düşer VE
-- base_cortisol_recovery_rate kalıcı olarak %20 küçülür (BurnoutRecoveryRateFloor
-- altına asla inmez). Bu, "anında çöküş" değil "1 saatlik sürdürülebilir aşırı
-- çalışmanın kalıcı bedeli" mantığıdır - bkz. config.lua'daki Yarılanma Ömrü notu.
-- KARMAŞIKLIK: O(1) per bot per dakika; N bot için toplam O(N) (master
-- ticker zaten tüm botları geziyor, ek bir tarama YOK).
function Matrix.Kitchen.ProcessMinuteCycle(bot)
    -- ★ FAZ 6 - ADIM 2: Botanik çekirdeği, master ticker'ın bir parçası
    -- olarak çalışır; ayrı bir thread/loop İCAT EDİLMEZ. Minute-bucket
    -- kapısı (aşağıda) sayesinde N bot için N kez çağrılsa bile gerçek
    -- iş YALNIZCA dakikada bir kez yapılır -> 0 Resmon.
    Matrix.Kitchen.ProcessBotanyCycle()

    local workFactor = Config.Kitchen.WorkFactor[bot.state.activity] or Config.Kitchen.WorkFactor.idle


    ApplyOrganicSkillGrowth(bot)


    bot.biology.fatigue_level = Matrix.Clamp(
        bot.biology.fatigue_level + (workFactor * (2.0 - bot.psychology.cognitive_shifter)),
        0.0, 1.0
    )


    if bot.biology.fatigue_level > Config.Kitchen.FatigueWarningThreshold then
        bot.biology.cortisol_level = Matrix.Clamp(bot.biology.cortisol_level + Config.Kitchen.FatigueCortisolBleed, 0.0, 1.0)
    end


    if bot.biology.fatigue_level > Config.Kitchen.FatigueCriticalThreshold then
        if not bot.biology.fatigue_critical_since then
            bot.biology.fatigue_critical_since = Matrix.Now()
        elseif not bot.biology.burned_this_episode
            and (Matrix.Now() - bot.biology.fatigue_critical_since) >= Config.Kitchen.FatigueCriticalDurationSeconds then
            bot.psychology.resilience = Matrix.Clamp(bot.psychology.resilience - Config.Kitchen.BurnoutResilienceLoss, 0.0, 1.0)
            bot.biology.base_cortisol_recovery_rate = math.max(
                bot.biology.base_cortisol_recovery_rate * (1.0 - Config.Kitchen.BurnoutRecoveryRatePenalty),
                Config.Kitchen.BurnoutRecoveryRateFloor
            )
            bot.biology.burned_this_episode = true
            Matrix.Log(
                'KITCHEN',
                '[TÜKENMİŞLİK] Bot #%d 60dk kritik yorgunluk eşiğini aştı. Direnç -%.2f, kortizol toparlanma oranı sabote edildi (%.4f).',
                bot.id, Config.Kitchen.BurnoutResilienceLoss, bot.biology.base_cortisol_recovery_rate
            )
        end
    else
        bot.biology.fatigue_critical_since = nil
        bot.biology.burned_this_episode = false
    end


    bot.biology.cortisol_level = Matrix.Clamp(
        bot.biology.cortisol_level - (bot.biology.base_cortisol_recovery_rate * bot.psychology.resilience),
        0.0, 1.0
    )


    


    Matrix.PersistBot(bot)


    -- ★ [OPSEC-3] Cete Sadakati / Ic Hirsizlik -- bkz. dosya sonundaki blok.
    -- MEVCUT per-bot dakika dongusune eklenir, ayri bir tick/thread ICAT
    -- EDILMEZ (0 Resmon butcesi korunur).
    Matrix.Kitchen.ProcessTrustWithdrawalTheft(bot)
end


-- FORMÜL (her GERÇEK saatte bir): withdrawal' = min(1.0, withdrawal +
-- addiction_level * WithdrawalGainPerAddictionPoint). addiction_level [0,100]
-- aralığında olduğundan bu DOĞRUSAL bir birikimdir, üst sınır 1.0'da SERT
-- kesilir (asimptotik değil - gerçek yoksunluk sendromunun "aniden patlak
-- verme" doğasını yansıtır). OYNANABİLİRLİK KİLİDİ: katsayı, addiction_level
-- >=20 olan bir botun TEK bir saatlik döngüde tam yoksunluğa ulaşmasını
-- (0.05'te olurdu) önlemek için 0.02'ye ayarlandı - bkz config.lua.
function Matrix.Kitchen.ProcessHourCycle(bot)
    if bot.biology.addiction_level > 0.0 then
        bot.biology.withdrawal_index = math.min(
            1.0, bot.biology.withdrawal_index + (bot.biology.addiction_level * Config.Kitchen.WithdrawalGainPerAddictionPoint)
        )
        Matrix.Log('KITCHEN', 'Bot #%d yoksunluk endeksi: %.2f', bot.id, bot.biology.withdrawal_index)
    end
end


-- Withdrawal eşiği (0.7) üzerinde TÜM teknik beceriler (chemistry/cyber/
-- logistics fark etmez, skillKey parametrik) %50 cezalandırılır - motorik
-- koordinasyon çöküşünün genel formülü budur. KARMAŞIKLIK: O(1).
function Matrix.Kitchen.GetEffectiveSkill(actor, skillKey)
    local baseSkill = (actor.psychology and actor.psychology[skillKey]) or 0.0
    local withdrawalIndex = (actor.biology and actor.biology.withdrawal_index) or 0.0


    if withdrawalIndex > Config.Kitchen.WithdrawalSkillPenaltyThreshold then
        return baseSkill * Config.Kitchen.WithdrawalSkillPenaltyMultiplier
    end


    return baseSkill
end


function Matrix.Kitchen.AdjustCortisol(actorRef, spikeType)
    local actor = Matrix.ResolveActor(actorRef)
    if not actor or not actor.biology then return end


    local delta = 0.0
    if spikeType == 'gunshot' then
        delta = Config.Kitchen.CortisolSpike.Gunshot
    elseif spikeType == 'bureau_vehicle' then
        delta = Config.Kitchen.CortisolSpike.BureauVehicle
    end


    actor.biology.cortisol_level = Matrix.Clamp(actor.biology.cortisol_level + delta, 0.0, 1.0)
    Matrix.Log('KITCHEN', 'Kortizol sıçraması (%s): %s -> %.2f', spikeType, actor.dna_id, actor.biology.cortisol_level)
end


-- Bot İçi İhbar: bağımlı bir bot mutfaktan çalarken, aynı trap house'ta
-- duran ("temiz", addiction_level<=0) en düşük ID'li bot merkeze telsiz
-- cızırtısıyla iç ihbar geçer (deterministik seçim, RNG yok).
local function FindCleanBotAtTrapHouse(trapHouseId, excludeBotId)
    local foundId, foundBot = nil, nil
    for id, b in pairs(Matrix.Bots) do
        if id ~= excludeBotId and b.status == 'active' and b.state.trap_house_id == trapHouseId
            and (b.biology.addiction_level or 0.0) <= 0.0 then
            if not foundId or id < foundId then
                foundId, foundBot = id, b
            end
        end
    end
    return foundId, foundBot
end


local function BroadcastCleanBotTip(trapHouseId, thiefDnaId, excludeBotId)
    local cleanId, cleanBot = FindCleanBotAtTrapHouse(trapHouseId, excludeBotId)
    if not cleanBot then return end


    Matrix.Log('KITCHEN', '[BZZZT] Merkez, %s\'in elleri titriyordu, tartı sapmalı. (Bildiren: Bot #%d %s)',
        thiefDnaId, cleanId, cleanBot.name)
end


-- =====================================================================
-- ★★★ [MATRIX:PHARMACOLOGICAL_DILUTION_CORE] ★★★
-- FORMÜL SETİ (Mutfak Motoru - GERÇEK farmakolojik seyreltme/kesme,
-- C1*V1 = C2*V2 kütle-konsantrasyon korunum yasası):
--
--   M_pure              = rawWeight * rawPurity                 [saf madde kütlesi]
--   V_total             = rawWeight + agentWeight               [kesme ajanı sonrası toplam hacim]
--   C2_ideal            = M_pure / V_total                      [ideal farmakolojik konsantrasyon]
--   error_coefficient   = ((1-skill_chemistry)*0.5) + (fatigue*0.3) + (cortisol*0.2)
--   final_output_purity = C2_ideal * (1 - error_coefficient)
--
-- MOLEKÜLER DOYUM & ASİMPTOTİK GÜVENLİK TABANI (CRITICAL REJECTION):
--   final_output_purity <= MinPurityFloor (0.05) ise, bileşik MUTLAK
--   doyuma ulaşmıştır -- fazla kesme ajanı moleküler olarak BAĞLANMAYI
--   REDDEDER. waste_volume, normal 0.20 çarpanı yerine SERTLEŞTİRİLMİŞ
--   0.35 çarpanıyla ŞİŞİRİLİR (malzeme yapısı tahrip edilir) ve çıkış
--   saflığı KESİN olarak 0.05'e clamp edilir. Bu, modern adli kimyada
--   "aşırı seyreltme -> çökelme/ayrışma" olgusunun deterministik
--   matematiksel karşılığıdır.
--
-- Yorum: error_coefficient üç bağımsız insani faktörün AĞIRLIKLI TOPLAMIDIR
-- (ağırlıklar 0.5/0.3/0.2 -> toplam 1.0, yani error_coefficient teorik
-- olarak [0,1] aralığında kalır çünkü her terim de [0,1] aralığındadır).
-- theft_amount SADECE withdrawal_index >= TheftWithdrawalThreshold (1.0)
-- olduğunda tetiklenir - eşik-tabanlı, ADIM fonksiyonu (RNG değil, keskin
-- bir davranışsal kriz noktası). KARMAŞIKLIK: O(1); tek senkron DB insert
-- (event-tetiklemeli, master ticker'ı bloklamaz). SIFIR RNG.
-- =====================================================================
function Matrix.Kitchen.ComputePharmacologicalDilution(rawWeight, rawPurity, agentWeight, skillChemistry, fatigueLevel, cortisolLevel)
    -- 1) Kütle-konsantrasyon korunumu (C1 * V1 = C2 * V2).
    local M_pure   = rawWeight * rawPurity
    local V_total  = rawWeight + agentWeight
    local C2_ideal = (V_total > 0.0) and (M_pure / V_total) or 0.0

    -- 2) Biyolojik & insani sürtünme katsayısı (0 RNG, ağırlıklı toplam).
    local errorCoefficient = ((1.0 - skillChemistry) * 0.5)
                           + (fatigueLevel * 0.3)
                           + (cortisolLevel * 0.2)

    -- 3) İdeal farmakolojik saflığa insani hata düzeltmesi.
    local finalOutputPurity = C2_ideal * (1.0 - errorCoefficient)

    -- 4) Moleküler doyum ve güvenlik tabanı.
    local floor = (Config.Kitchen.Packaging and Config.Kitchen.Packaging.MinPurityFloor) or 0.05
    local saturationWasteMultiplier = Config.Kitchen.SaturationWasteMultiplier or 0.35
    local normalWasteMultiplier     = Config.Kitchen.NormalWasteMultiplier     or 0.20

    local molecularSaturation = false
    local wasteVolume
    if finalOutputPurity <= floor then
        -- MOLEKÜLER BAĞLANMA REDDİ: kesme ajanı artık bağlanmaz, yapı tahrip olur.
        molecularSaturation = true
        finalOutputPurity   = floor
        wasteVolume         = agentWeight * errorCoefficient * saturationWasteMultiplier
    else
        wasteVolume         = agentWeight * errorCoefficient * normalWasteMultiplier
    end

    return {
        theoretical_purity   = C2_ideal,
        error_coefficient    = errorCoefficient,
        output_purity        = finalOutputPurity,
        waste_volume         = wasteVolume,
        molecular_saturation = molecularSaturation,
        M_pure               = M_pure,
        V_total              = V_total,
    }
end


function Matrix.Kitchen.ProcessCook(actorRef, trapHouseId, rawWeight, rawPurity, agentWeight)
    local actor = Matrix.ResolveActor(actorRef)
    if not actor then return nil end

    -- ★ v6.6.4-A2d: KATI GİRDİ DOĞRULAMA (fail-closed).
    -- Client (reportCookAction) ve /mutfaktest doğrudan buraya bağlıydı;
    -- NaN/Inf/aşırı miktar inputları kabul ediliyordu → sınırsız üretim.
    trapHouseId = tonumber(trapHouseId)
    if not trapHouseId or not (Matrix.TrapHouses and Matrix.TrapHouses[trapHouseId]) then
        Matrix.Log('KITCHEN', '[HATA][v6.6.4] ProcessCook: gecersiz trapHouseId=%s', tostring(trapHouseId))
        return nil
    end

    rawWeight   = tonumber(rawWeight)
    rawPurity   = tonumber(rawPurity)
    agentWeight = tonumber(agentWeight)

    local function _badNum(v)
        return (not v) or v ~= v or v == math.huge or v == -math.huge
    end
    if _badNum(rawWeight) or _badNum(rawPurity) or _badNum(agentWeight) then
        Matrix.Log('KITCHEN', '[HATA][v6.6.4] ProcessCook: NaN/Inf girdi reddedildi (rw=%s rp=%s aw=%s)',
            tostring(rawWeight), tostring(rawPurity), tostring(agentWeight))
        return nil
    end
        if rawWeight <= 0.0 or rawWeight > 100000.0 then return nil end
    if rawPurity < 0.0 or rawPurity > 1.0        then return nil end
    if agentWeight < 0.0 or agentWeight > 100000.0 then return nil end

    -- ★ v6.6.4-A2d: STASH GİRDİ DOĞRULAMA + TÜKETİM (fail-closed).
    -- Önceden malzeme hiç tüketilmeden çıktı üretiliyordu → sınırsız pişirim.
    -- Şimdi trap house deposunda yeterli raw/agent yoksa işlem reddedilir;
    -- varsa formülden ÖNCE tüketilir (atomik değil ama her başarılı pişirim
    -- için gerçek bir girdi harcanmış olur).
    local _stashId     = ('matrix_trap_stash_%d'):format(trapHouseId)
    local _rawItem     = (Config.Kitchen.Packaging and Config.Kitchen.Packaging.RawItem) or 'meth_raw_batch'
    local _cuttingItem = (Config.Kitchen.Packaging and Config.Kitchen.Packaging.CuttingAgentItem) or 'cutting_agent'

    local _rawOk, _rawAvail = pcall(function() return exports['ox_inventory']:Search(_stashId, 'count', _rawItem) end)
    local _cutOk, _cutAvail = pcall(function() return exports['ox_inventory']:Search(_stashId, 'count', _cuttingItem) end)
    _rawAvail = (_rawOk and tonumber(_rawAvail)) or 0
    _cutAvail = (_cutOk and tonumber(_cutAvail)) or 0

    if _rawAvail < rawWeight then
        Matrix.Log('KITCHEN', '[HATA][v6.6.4] ProcessCook: yetersiz %s (mevcut=%.2f istenen=%.2f)',
            _rawItem, _rawAvail, rawWeight)
        return nil
    end
    if _cutAvail < agentWeight then
        Matrix.Log('KITCHEN', '[HATA][v6.6.4] ProcessCook: yetersiz %s (mevcut=%.2f istenen=%.2f)',
            _cuttingItem, _cutAvail, agentWeight)
        return nil
    end

    -- Tüketim — formülden ÖNCE. Başarısızsa işlem iptal, çıktı üretilmez.
    if rawWeight > 0.0 then
        local _rmRawOk, _rmRawRes = pcall(function()
            return exports['ox_inventory']:RemoveItem(_stashId, _rawItem, rawWeight)
        end)
        if not (_rmRawOk and _rmRawRes == true) then
            Matrix.Log('KITCHEN', '[HATA][v6.6.4] ProcessCook: %s tuketimi basarisiz.', _rawItem)
            return nil
        end
    end
    if agentWeight > 0.0 then
        local _rmCutOk, _rmCutRes = pcall(function()
            return exports['ox_inventory']:RemoveItem(_stashId, _cuttingItem, agentWeight)
        end)
        if not (_rmCutOk and _rmCutRes == true) then
            Matrix.Log('KITCHEN', '[HATA][v6.6.4] ProcessCook: %s tuketimi basarisiz; %s telafi ediliyor.',
                _cuttingItem, _rawItem)
            pcall(function() exports['ox_inventory']:AddItem(_stashId, _rawItem, rawWeight) end)
            return nil
        end
    end


    local skillChemistry = Matrix.Kitchen.GetEffectiveSkill(actor, 'skill_chemistry')

    local fatigueLevel   = (actor.biology and actor.biology.fatigue_level) or 0.0
    local cortisolLevel  = (actor.biology and actor.biology.cortisol_level) or 0.0
    local withdrawalIndex = (actor.biology and actor.biology.withdrawal_index) or 0.0
    local addictionLevel  = (actor.biology and actor.biology.addiction_level) or 0.0


    -- ★ [MATRIX:PHARMACOLOGICAL_DILUTION_CORE] Saf farmakolojik hesap
    -- çekirdeği -- yan etkisiz (pure), test edilebilir. Aynı formül
    -- ProcessCook tarafından da burada da çağrılır.
    local pharm = Matrix.Kitchen.ComputePharmacologicalDilution(
        rawWeight, rawPurity, agentWeight, skillChemistry, fatigueLevel, cortisolLevel)


    local theoreticalPurity = pharm.theoretical_purity
    local errorCoefficient  = pharm.error_coefficient
    local outputPurity      = pharm.output_purity
    local wasteVolume       = pharm.waste_volume


    if pharm.molecular_saturation then
        Matrix.Log(
            'KITCHEN',
            '[MATRIX:PHARMACOLOGICAL_DILUTION_CORE] MOLEKÜLER BAĞLANMA REDDİ: C2_ideal=%.4f <= taban=%.4f -- kesme ajanı moleküler olarak bağlanmadı, waste_volume=%.3fg (0.35x amplifikasyon), çıkış saflığı %.4f\'e SABİTLENDİ.',
            theoreticalPurity,
            (Config.Kitchen.Packaging and Config.Kitchen.Packaging.MinPurityFloor) or 0.05,
            wasteVolume, outputPurity
        )
    end


    local theftAmount = 0.0
    if withdrawalIndex >= Config.Kitchen.TheftWithdrawalThreshold then
        theftAmount = addictionLevel * Config.Kitchen.TheftGramsPerAddictionPoint
        Matrix.Log(
            'KITCHEN',
            '[MATRIX:PHARMACOLOGICAL_DILUTION_CORE][SİSTEMİK ANOMALİ: LABORATUVAR HASSAS TARTI SAPMASI] %s, %.1fg mal çaldı.',
            actor.dna_id, theftAmount
        )
        BroadcastCleanBotTip(trapHouseId, actor.dna_id, actor.id)
    end


    local finalWeight = math.max((rawWeight + agentWeight) - wasteVolume - theftAmount, 0.0)
    local rivalInfiltration = outputPurity < Config.Kitchen.RivalInfiltrationPurityThreshold


    MySQL.query.await([[
        INSERT INTO matrix_kitchen_batches (
            trap_house_id, actor_identifier, raw_weight, raw_purity, agent_weight,
            theoretical_purity, error_coefficient, output_purity, waste_volume,
            theft_amount, rival_infiltration_triggered, created_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NOW())
    ]], {
        trapHouseId, actor.dna_id, rawWeight, rawPurity, agentWeight,
        theoreticalPurity, errorCoefficient, outputPurity, wasteVolume,
        theftAmount, rivalInfiltration and 1 or 0
    })


    if rivalInfiltration then
        Matrix.Log('KITCHEN', '[MATRIX:PHARMACOLOGICAL_DILUTION_CORE][RAKİP SIZMA TETİKLEYİCİSİ] Trap house #%d saflık %.2f ile kritik eşiğin altında.', trapHouseId, outputPurity)
    end


    -- ★ KATMAN 7 FAZ 2: ProcessCook'un KENDİ formülüne (yukarıda) HİÇ
    -- dokunulmadı -- yalnızca zaten hesaplanmış finalWeight/outputPurity,
    -- main.lua'nın Matrix.DepositDealerCargoToTrapStash İLE AYNI RegisterStash/
    -- AddItem kalıbıyla trap house deposuna (matrix_trap_stash_<id>) FİZİKSEL
    -- bir "ham parti" (Config.Kitchen.Packaging.RawItem) olarak yazılır.
    -- Paketleme Odası (Matrix.Kitchen.PackageBatch, aşağıda) bunu tüketir.
    -- Best-effort/pcall-korumalı: ox_inventory kullanılamazsa sessizce
    -- atlanır (batch verisi zaten yukarıda DB'ye yazıldı, script çökmez).
    -- ox_inventory item sayaçları tamsayıdır (gram = adet varsayımı); küsurat
    -- YUKARI YUVARLANMAZ (kütle korunumu ihlali olmasın diye taban alınır).
    -- ★ [M-3 FIX] Küsurat biriktirici — math.floor ile kaybolan ondalıklar
    -- trap-house başına birikir; tam gram oluşunca depoya eklenir. Böylece
    -- hiçbir gram "hayalet" olarak kaybolmaz (kütle korunumu tam).
    local depositGrams = math.floor(finalWeight)
    local remainder    = finalWeight - depositGrams

    local partialKey = trapHouseId
    _KitchenPartialGrams[partialKey] = (_KitchenPartialGrams[partialKey] or 0.0) + remainder

    if _KitchenPartialGrams[partialKey] >= 1.0 then
        local carryGrams = math.floor(_KitchenPartialGrams[partialKey])
        _KitchenPartialGrams[partialKey] = _KitchenPartialGrams[partialKey] - carryGrams
        depositGrams = depositGrams + carryGrams
        Matrix.Log('KITCHEN',
            '[M-3 KÜSURAT TELAFİ] Trap #%d: %.3fg birikmiş ondalık tam grama çevrildi (+%d gram).',
            trapHouseId, _KitchenPartialGrams[partialKey] + carryGrams, carryGrams)
    end

    if depositGrams >= 1 then
        local stashId = ('matrix_trap_stash_%d'):format(trapHouseId)
        local house = Matrix.TrapHouses and Matrix.TrapHouses[trapHouseId]
        local stashLabel = (house and house.label and ('%s Deposu'):format(house.label))
            or ('Trap House #%d Deposu'):format(trapHouseId)

        pcall(function()
            exports['ox_inventory']:RegisterStash(stashId, stashLabel, 100, 200000)
        end)
        pcall(function()
            exports['ox_inventory']:AddItem(stashId, Config.Kitchen.Packaging.RawItem, depositGrams, { purity = outputPurity })
        end)
    end

    return {
        theoretical_purity   = theoreticalPurity,
        error_coefficient    = errorCoefficient,
        output_purity        = outputPurity,
        waste_volume         = wasteVolume,
        theft_amount         = theftAmount,
        final_weight         = finalWeight,
        rival_infiltration   = rivalInfiltration,
        molecular_saturation = pharm.molecular_saturation,
    }
end



-- FORMÜL: I_snitch = 0.3*snitch_tendency + 0.3*economic_pressure +
--   0.2*cortisol + 0.2*fear_factor - 0.2*resilience
-- Ağırlıklı toplam [-0.2, 1.0] aralığında (resilience terimi negatif katkı
-- yapar); Config.Kitchen.SnitchThreshold (0.75) ile karşılaştırılır. Her
-- terim bağımsız gözlemlenebilir bir bot alanına karşılık gelir -> bu formül
-- deterministiktir ve /yakalatest ile RNG olmadan tekrar üretilebilir.
function Matrix.Kitchen.ComputeSnitchIndex(bot)
    return (bot.psychology.snitch_tendency * 0.3)
        + (bot.psychology.economic_pressure * 0.3)
        + (bot.biology.cortisol_level * 0.2)
        + (bot.psychology.fear_factor * 0.2)
        - (bot.psychology.resilience * 0.2)
end


-- =====================================================================
-- ★★★ [OPSEC FAZ 1 EK] HİYERARŞİK HÜCRE SİSTEMİ VE HAFIZA KAPSÜLLEME
-- (NEED-TO-KNOW) — matrix_knowledge_mask ★★★
-- TAMAMEN YENİ bir EKLEMEDİR. matrix_bots şemasına YENİ bir sütun
-- EKLENMEZ — server/bureau.lua PolicePersonalityCache/learningCore,
-- server/forensics.lua BallisticCache İLE AYNI "bot verisinin YANINDA,
-- botId ile anahtarlanan bağımsız bir RAM yan-tablosu" konvansiyonu
-- izlenir. Kalıcı bir sütun/tablo GEREKMEZ çünkü maske botun O ANKİ
-- rolünden DETERMİNİSTİK olarak yeniden inşa edilebilir — sunucu
-- restart'ında bot yeniden yüklendiğinde (LoadBotsFromDatabase, main.lua)
-- ilk erişimde otomatik olarak doğru şekilde yeniden kurulur.
--
-- KURAL: 'dealer' rolündeki bir bot yalnızca kendi bölgesini (zone_id —
-- Matrix.Market.FindNearestZone İLE AYNI mevcut bölge-eşlemesi, YENİ bir
-- bölge kavramı İCAT EDİLMEZ) bilir, trap house'un (ana üssün) TAM
-- konumunu/kimliğini BİLMEZ. 'runner' (lojistik) rolündeki bir bot ise
-- tedarik zincirinin Dead Drop koordinatlarını (Config.Supplier.DeadDrops)
-- öğrenir. Diğer roller (Inspector vb.) için MEVCUT davranış (tam bilgi)
-- KORUNUR — talep yalnızca 'dealer' için AÇIK bir kısıtlama istedi, başka
-- rollere yeni bir kısıtlama İCAT EDİLMEZ.
--
-- Rol değiştiğinde (örn. bir dealer lojistiğe kaydırılırsa)
-- Matrix.Kitchen.FlushKatmanKnowledge(botId) ESKİ maskeyi kalıcı olarak
-- siler; GetOrCreateKnowledgeMask'in kendi stale-role tespiti bunun
-- ÜZERİNE bir GÜVENLİK AĞIDIR (Flush çağrılması UNUTULSA bile maske ASLA
-- eski role ait kalmaz — server/market.lua ZoneInspectors'ın kendi kendini
-- iyileştirmesiyle AYNI disiplin).
-- =====================================================================
local KnowledgeMaskByBotId = {} -- [botId] = { role_snapshot, zone_id, knows_main_base, known_dead_drops }


local function BuildKnowledgeMaskForRole(bot)
    local mask = {
        role_snapshot    = bot.role,
        zone_id          = nil,
        knows_main_base  = false,
        known_dead_drops = {}
    }


    if bot.role == 'dealer' then
        -- ★ Yalnızca kendi bölgesini bilir -- ana üssü (trap house) BİLMEZ.
        local house = bot.state.trap_house_id and Matrix.TrapHouses and Matrix.TrapHouses[bot.state.trap_house_id]
        if house and house.coords and Matrix.Market and Matrix.Market.FindNearestZone then
            mask.zone_id = Matrix.Market.FindNearestZone(house.coords)
        end
        mask.knows_main_base = false
    elseif bot.role == 'runner' then
        -- ★ Lojistik: ana üssü bilir (kargoyu oraya taşıyor) VE tedarik
        -- zincirinin Dead Drop koordinatlarını öğrenir.
        mask.knows_main_base = true
        for _, drop in ipairs((Config.Supplier and Config.Supplier.DeadDrops) or {}) do
            mask.known_dead_drops[drop.id] = true
        end
    else
        -- Diğer roller (Inspector vb.): MEVCUT davranış (tam bilgi)
        -- KORUNUR -- yeni bir kısıtlama İCAT EDİLMEZ.
        mask.knows_main_base = true
    end


    return mask
end


--- Botun GÜNCEL katman-bilgisi maskesini döner; yoksa VEYA rolü son
--- inşadan beri değiştiyse (Flush çağrılmamış olsa bile) SIFIRDAN inşa
--- edilir.
local function GetOrCreateKnowledgeMask(bot)
    if not bot then return nil end
    local mask = KnowledgeMaskByBotId[bot.id]
    if not mask or mask.role_snapshot ~= bot.role then
        mask = BuildKnowledgeMaskForRole(bot)
        KnowledgeMaskByBotId[bot.id] = mask
    end
    return mask
end


--- ★ [OPSEC-4] Bir bot rol değiştirdiğinde (örn. dealer -> lojistik)
--- ESKİ katman bilgisini kalıcı olarak siler; hemen ardından botun YENİ
--- rolüne göre SIFIRDAN bir maske inşa eder (boş bırakılmaz). Rol
--- değişikliğini tetikleyen kod NEREDE olursa olsun (server/market.lua
--- Inspector ataması, gelecekteki bir lojistik-kaydırma komutu vb.) bu
--- fonksiyonu çağırarak GARANTİLİ bir temizlik sağlayabilir; çağrılması
--- unutulsa bile GetOrCreateKnowledgeMask'in stale-role tespiti (yukarıda)
--- aynı sonucu (bir sonraki erişimde) üretir.
function Matrix.Kitchen.FlushKatmanKnowledge(botId)
    botId = tonumber(botId)
    if not botId then return false end


    KnowledgeMaskByBotId[botId] = nil


    local bot = Matrix.Bots[botId]
    if bot then
        local newMask = GetOrCreateKnowledgeMask(bot)
        Matrix.Log('KITCHEN',
            '[OPSEC][KATMAN TEMIZLENDI] Bot #%d (%s) -> eski illegal veri zihinden silindi, yeni rol (%s) icin sifirdan maske kuruldu (zone_id=%s, ana-us-bilgisi=%s).',
            botId, bot.dna_id, bot.role, tostring(newMask.zone_id), tostring(newMask.knows_main_base))
    end


    return true
end


--- Salt-okunur getter -- diğer modüller (veya debug panel) botun güncel
--- maskesini gözlemlemek isterse.
function Matrix.Kitchen.GetKnowledgeMask(botId)
    local bot = Matrix.Bots[tonumber(botId)]
    if not bot then return nil end
    return GetOrCreateKnowledgeMask(bot)
end


function Matrix.Kitchen.OnCaptured(botId, trapHouseId)
    local bot = Matrix.Bots[botId]
    if not bot then return nil end


    local snitchIndex = Matrix.Clamp(Matrix.Kitchen.ComputeSnitchIndex(bot), -1.0, 1.0)


    -- ★ [OPSEC FAZ 1 EK] FearCoefficient: taban SnitchThreshold
    -- (DEĞİŞTİRİLMEDİ) yerine çetenin infaz geçmişine göre YÜKSELTİLMİŞ
    -- efektif eşik kullanılır (bkz. server/bureau.lua
    -- GetEffectiveSnitchThreshold). Hook yoksa davranış BİREBİR ESKİSİ
    -- GİBİDİR (taban eşiğe düşer).
    local effectiveThreshold = (Matrix.Bureau and Matrix.Bureau.GetEffectiveSnitchThreshold and Matrix.Bureau.GetEffectiveSnitchThreshold())
        or Config.Kitchen.SnitchThreshold
    local didSnitch = snitchIndex >= effectiveThreshold


    MySQL.query.await([[
        INSERT INTO matrix_snitch_events (bot_id, trap_house_id, snitch_index, lied, created_at)
        VALUES (?, ?, ?, ?, NOW())
    ]], { botId, trapHouseId, snitchIndex, didSnitch and 0 or 1 })


    if didSnitch then
        Matrix.Log(
            'KITCHEN', 'Bot #%d yakalandı ve Büro ile trap house #%d verilerini paylaştı (I_snitch %.2f/%.2f)',
            botId, trapHouseId, snitchIndex, effectiveThreshold
        )


        -- ★ [OPSEC-4] NEED-TO-KNOW: kırılan bot yalnızca KENDİ
        -- matrix_knowledge_mask sınırları dahilindeki bilgiyi sızdırır --
        -- tüm organizasyonu DEĞİL.
        local mask = GetOrCreateKnowledgeMask(bot)
        if mask and mask.knows_main_base then
            -- Tam bilgi: MEVCUT davranış (ESKİ, DEĞİŞTİRİLMEDİ) -- bot
            -- kendi trap house'unu zaten tam olarak biliyordu.
            Matrix.Bureau.ReceiveSnitchLeak(trapHouseId)
        elseif mask and mask.zone_id then
            -- ★ KISITLI SIZINTI: bot yalnızca kendi bölgesini biliyordu --
            -- Büro'ya bu SPESİFİK trap house'un kimliği/konumu SIZMAZ;
            -- yalnızca o bölgedeki (Matrix.Market.FindNearestZone İLE AYNI
            -- eşleme) TÜM trap house'lara ZAYIF bir propaganda darbesi
            -- (Matrix.Bureau.TriggerPropaganda, MEVCUT/DEĞİŞTİRİLMEDİ)
            -- uygulanır -- yeni bir sızıntı formülü İCAT EDİLMEZ, yalnızca
            -- hedef DARALTILIR.
            local leakedCount = 0
            for otherId, house in pairs(Matrix.TrapHouses or {}) do
                if house.coords and Matrix.Market and Matrix.Market.FindNearestZone
                    and Matrix.Market.FindNearestZone(house.coords) == mask.zone_id then
                    Matrix.Bureau.TriggerPropaganda(otherId)
                    leakedCount = leakedCount + 1
                end
            end
            Matrix.Log('KITCHEN',
                '[OPSEC][KISITLI SIZINTI] Bot #%d yalnizca Bolge #%s biliyordu -- ana us (Trap #%d) KORUNDU, bolgedeki %d trap house zayif propaganda darbesi aldi.',
                botId, tostring(mask.zone_id), trapHouseId, leakedCount)
        else
            -- Maske boş/çözülemedi: hiçbir şey bilmiyordu -- en
            -- muhafazakar/güvenli varsayılan: HİÇBİR SIZINTI olmaz.
            Matrix.Log('KITCHEN',
                '[OPSEC][SIZINTI YOK] Bot #%d matrix_knowledge_mask sinirlari icinde sizdiracak bilgiye sahip degildi.', botId)
        end
    else
        Matrix.Log(
            'KITCHEN', '[UYARI: TELSİZ FREKANSI SES ANALİZİ - %%%.0f SAPMA] Bot #%d sorguda yalan söyledi (esik:%.2f).',
            bot.biology.cortisol_level * 100, botId, effectiveThreshold
        )
    end


    return snitchIndex, didSnitch
end


-- =====================================================================
-- ★★★ KATMAN 7 FAZ 2: PAKETLEME ODASI ★★★
-- ProcessCook'un (yukarıda) trap house deposuna bıraktığı ham partiyi
-- (Config.Kitchen.Packaging.RawItem) kesme ajanıyla (CuttingAgentItem)
-- karıştırıp Config.Kitchen.Packaging.PackageGrams'lık kurye paketlerine
-- (meth_bag/coke_brick, metadata.purity taşıyan) dönüştürür.
--
-- FORMÜL (kütle korunumu -- ProcessCook'un theoretical_purity/kütle
-- korunumu FELSEFESİYLE AYNI):
--   rawPerPackage = PackageGrams - CuttingAgentGramsPerPackage
--   avgPurity     = Σ(slot.weight*slot.purity) / Σ(slot.weight)   (depodaki
--                   TÜM ham parti slotlarının ağırlıklı ortalaması --
--                   birden fazla pişirim farklı saflıkta partiler bırakmış
--                   olabilir)
--   outputPurity  = max(avgPurity - CuttingAgentGramsPerPackage*
--                   PurityDilutionPerCutGram, MinPurityFloor)
-- Üretilebilecek paket sayısı, hem depodaki ham madde hem kesme ajanı
-- stoğuyla SINIRLANDIRILIR (eksik stoktan fazla paket İCAT EDİLMEZ) --
-- SIFIR RNG, saf kütle/stok muhasebesi.
-- =====================================================================
function Matrix.Kitchen.PackageBatch(trapHouseId, productItem, packageCount)
    trapHouseId  = tonumber(trapHouseId)
    packageCount = tonumber(packageCount)
    if not trapHouseId or not Matrix.TrapHouses[trapHouseId] then return nil, 'bad_trap_house' end
    if not packageCount or packageCount <= 0 then return nil, 'bad_count' end
    packageCount = math.min(math.floor(packageCount), Config.Kitchen.Packaging.MaxPackagesPerRun)


    local productLabel
    for _, product in ipairs(Config.Kitchen.Packaging.Products) do
        if product.item == productItem then productLabel = product.label break end
    end
    if not productLabel then return nil, 'bad_product' end


    local stashId = ('matrix_trap_stash_%d'):format(trapHouseId)
    local invOk, inv = pcall(function() return exports['ox_inventory']:GetInventory(stashId) end)
    if not invOk or type(inv) ~= 'table' or type(inv.items) ~= 'table' then return nil, 'no_stash' end


    -- Depodaki TÜM ham parti stoklarını topla (ağırlık-ağırlıklı ortalama saflık).
    local totalRawWeight, weightedPuritySum = 0.0, 0.0
    local rawSlots = {}
    for slot, item in pairs(inv.items) do
        if type(item) == 'table' and item.name == Config.Kitchen.Packaging.RawItem then
            local weight = tonumber(item.count) or 0.0
            local purity = (item.metadata and tonumber(item.metadata.purity)) or 0.0
            if weight > 0.0 then
                rawSlots[#rawSlots + 1] = { slot = slot, weight = weight, purity = purity }
                totalRawWeight = totalRawWeight + weight
                weightedPuritySum = weightedPuritySum + (weight * purity)
            end
        end
    end
    if totalRawWeight <= 0.0 then return nil, 'no_raw_material' end


    local avgPurity     = weightedPuritySum / totalRawWeight
    local rawPerPackage = Config.Kitchen.Packaging.PackageGrams - Config.Kitchen.Packaging.CuttingAgentGramsPerPackage
    local cutPerPackage = Config.Kitchen.Packaging.CuttingAgentGramsPerPackage


    local cutOk, cutAvailable = pcall(function()
        return exports['ox_inventory']:Search(stashId, 'count', Config.Kitchen.Packaging.CuttingAgentItem)
    end)
    cutAvailable = (cutOk and tonumber(cutAvailable)) or 0


    local maxByRaw = math.floor(totalRawWeight / rawPerPackage)
    local maxByCut = math.floor(cutAvailable / cutPerPackage)
    packageCount   = math.min(packageCount, maxByRaw, maxByCut)
    if packageCount <= 0 then return nil, 'insufficient_materials' end


    local outputPurity = math.max(
        avgPurity - (cutPerPackage * Config.Kitchen.Packaging.PurityDilutionPerCutGram),
        Config.Kitchen.Packaging.MinPurityFloor
    )


    -- ★ CRITICAL FIX: her iki RemoveItem de ARTIK yalnizca pcall (hata var
    -- mi?) degil, GERCEK basari boolean'i (2. donus degeri) ile guard'lanir.
    -- Onceden bu cagrilar tamamen "ates et ve unut" idi -- ham madde/kesme
    -- ajani envanterden HIC cikmasa bile paket URETILIYORDU (bedava/dupe
    -- paket). Simdi tuketim basarisiz olursa islem ANINDA 'return'/'break'
    -- ile kesilir, AddItem'e ASLA ulasilmaz.

    -- Ham maddeyi slot slot (deterministik sıra: en düşük slot numarası önce) tüket.
    table.sort(rawSlots, function(a, b) return a.slot < b.slot end)
    local remainingToConsume = packageCount * rawPerPackage
    for _, entry in ipairs(rawSlots) do
        if remainingToConsume <= 0.0 then break end
        local take = math.min(entry.weight, remainingToConsume)
        local rawRemoveOk, rawRemoved = pcall(function()
            return exports['ox_inventory']:RemoveItem(stashId, Config.Kitchen.Packaging.RawItem, take, nil, entry.slot)
        end)
        if not (rawRemoveOk and rawRemoved == true) then
            Matrix.Log('KITCHEN',
                '[KRITIK] PackageBatch: Trap #%d RawItem (%s) tuketimi basarisiz (slot=%d) -- paket URETILMEDI.',
                trapHouseId, Config.Kitchen.Packaging.RawItem, entry.slot)
            return nil, 'raw_consume_failed'
        end
        remainingToConsume = remainingToConsume - take
    end
    if remainingToConsume > 0.0 then
        Matrix.Log('KITCHEN',
            '[KRITIK] PackageBatch: Trap #%d RawItem eksik tuketildi (kalan=%.2fg) -- paket URETILMEDI.',
            trapHouseId, remainingToConsume)
        return nil, 'raw_consume_incomplete'
    end


    local cutRemoveOk, cutRemoved = pcall(function()
        return exports['ox_inventory']:RemoveItem(stashId, Config.Kitchen.Packaging.CuttingAgentItem, packageCount * cutPerPackage)
    end)
    if not (cutRemoveOk and cutRemoved == true) then
        Matrix.Log('KITCHEN',
            '[KRITIK] PackageBatch: Trap #%d CuttingAgentItem (%s) tuketimi basarisiz -- paket URETILMEDI.',
            trapHouseId, Config.Kitchen.Packaging.CuttingAgentItem)
        return nil, 'cutting_agent_consume_failed'
    end


    local addOk, added = pcall(function()
        return exports['ox_inventory']:AddItem(stashId, productItem, packageCount, { purity = outputPurity })
    end)
    if not (addOk and added == true) then return nil, 'add_failed' end


        -- [FAZ 2.6 / P2e-1] Mission progress — trap house'ın aktif bot sahibine
    do
      local handlerCid = nil
      for _, b in pairs(Matrix.Bots or {}) do
        if b.status == 'active' and b.state
           and b.state.trap_house_id == trapHouseId
           and b.handler_citizenid then
          handlerCid = b.handler_citizenid
          break
        end
      end
      if handlerCid then
        TriggerEvent('matrix:internal:missions:progress',
                     handlerCid, 'uretim', { amount = packageCount })
      end
    end

    return {
        item   = productItem,


local function KitchenHasCommandAuthority(src)
    if not (Matrix.Hierarchy and Matrix.Hierarchy.HasCommandAuthority) then return true end
    local state = Matrix.GetOrCreatePlayerState(src)
    if not state or not state.citizenid then return false end
    return Matrix.Hierarchy.HasCommandAuthority(state.citizenid)
end


RegisterCommand('paketleuret', function(src, args)
    if not KitchenHasCommandAuthority(src) then
        Reply(src, 'Bu islemi yapmak icin yeterli rutbeniz yok (Logistics_Officer veya Leader gerekir).'); return
    end


    local trapHouseId = tonumber(args[1])
    local productItem = args[2]
    local packageCount = tonumber(args[3])
    if not trapHouseId or type(productItem) ~= 'string' or not packageCount then
        Reply(src, 'Kullanim: /paketleuret [trapHouseId] [meth_bag|coke_brick] [paketSayisi]'); return
    end


    local result, reason = Matrix.Kitchen.PackageBatch(trapHouseId, productItem, packageCount)
    if result then
        Reply(src, ('%dx %s uretildi (saflik:%.3f) -> Trap #%d deposu.'):format(
            result.count, result.label, result.purity, trapHouseId))
    else
        local messages = {
            bad_trap_house      = 'Gecersiz trap house.',
            bad_count           = 'Gecersiz paket sayisi.',
            bad_product         = 'Gecersiz urun (meth_bag veya coke_brick olmali).',
            no_stash            = 'Trap house deposuna erisilemedi.',
            no_raw_material     = 'Depoda ham parti yok (once mutfakta pisirim yapin).',
            insufficient_materials = 'Yetersiz ham madde veya kesme ajani stogu.',
            add_failed          = 'Paketler depoya eklenemedi (depo dolu olabilir).'
        }
        Reply(src, messages[reason] or ('Paketleme basarisiz: %s'):format(tostring(reason)))
    end
end, false)


RegisterNetEvent('matrix:server:reportCookAction', function(trapHouseId, rawWeight, rawPurity, agentWeight)
    local src = source
    if type(src) ~= 'number' or src <= 0 then return end
    -- ★ v6.6.4-A2d: pcall guard. ProcessCook içindeki stash tüketim/DB
    -- hataları bu event döngüsünü öldürmesin.
    local _ok, _err = pcall(Matrix.Kitchen.ProcessCook,
        { kind = 'player', source = src }, trapHouseId, rawWeight, rawPurity, agentWeight)
    if not _ok then
        Matrix.Log('KITCHEN', '[HATA][v6.6.4] reportCookAction basarisiz (yutuldu): %s', tostring(_err))
    end
end)


RegisterNetEvent('matrix:server:reportBotCaptured', function(botId, trapHouseId)
    Matrix.Kitchen.OnCaptured(botId, trapHouseId)
end)


RegisterNetEvent('matrix:server:reportCortisolTrigger', function(spikeType)
    local src = source
    Matrix.Kitchen.AdjustCortisol({ kind = 'player', source = src }, spikeType)
end)


-- =====================================================================
-- ★★★ [OPSEC FAZ 1] ÇETE SADAKATİ VE İÇ HIRSIZLIK (TRUST WITHDRAWAL
-- THEFT) ★★★
-- Aşağıdaki blok TAMAMEN YENİ bir EKLEMEDİR. ProcessCook/ProcessMinuteCycle/
-- ProcessHourCycle'ın (yukarıda) HİÇBİR formülüne dokunulmadı — tek
-- istisna, ProcessMinuteCycle'ın SONUNA eklenen tek satırlık bir çağrıdır
-- (bkz. o fonksiyonun güncellenmiş sonu).
--
-- Config.Kitchen.TheftWithdrawalThreshold (1.0) ve TheftGramsPerAddictionPoint
-- (10.0) ZATEN VAR — ProcessCook (yukarıda) bunları yalnızca AKTİF pişirim
-- sırasında (bir bot kendi partisinden çalarken) kullanıyordu. Burada AYNI
-- iki sabit, YENİ bir formül İCAT EDİLMEDEN, İKİNCİ bağımsız bir tetikleyiciye
-- bağlanır: matrix_supplier_trust'ın (server/logistics.lua — DEĞİŞTİRİLMEDİ,
-- bu dosyadan yalnızca salt-okunur bir SQL ortalaması ile OKUNUR) çete-geneli
-- ortalaması Config.Kitchen.TrustWithdrawalTheftTrustCeiling'in ALTINA
-- düşünce, yoksunluk eşiğini aşmış botlar ARTIK PİŞİRİM YAPMIYOR OLSALAR
-- BİLE trap house'un ortak deposundan (matrix_trap_stash_<id>, MEVCUT
-- ox_inventory stash — ProcessCook/PackageBatch İLE AYNI API) parça parça
-- çalmaya başlar. Sadakatlerini (psychology.loyalty_base — ZATEN VAR,
-- main.lua/recruitment.lua tarafından yazılıyor ama şimdiye kadar hiçbir
-- mekanik tarafından AZALTILMIYORDU) kaybederler — bu, o alanın İLK gerçek
-- tüketicisidir. Çalınan mal trap house'un ortak kirli-nakit hattına
-- (Matrix.CashDecay) YATIRILMAZ — "sokakta kendi hesaplarına satma"nın
-- oyun-ekonomisi karşılığı, bu değerin OYUNCUNUN kartelinden KALICI olarak
-- kaybolmasıdır (yeni bir paralel ekonomi/ceplenmiş-nakit sistemi İCAT
-- EDİLMEZ — yalnızca log/flavor amaçlı tahmini bir rakam basılır).
-- SIFIR RNG: her karar bir eşik karşılaştırmasıdır.
-- =====================================================================


-- Çete-geneli güven ortalaması: RAM önbellek + periyodik SQL yenileme
-- (forensics.lua BallisticCache / district_hubs.lua Hubs İLE AYNI "yükle,
-- sonra periyodik tazele" deseni). ProcessMinuteCycle'in HER çağrısında
-- (potansiyel olarak onlarca bot, her gerçek dakikada) senkron bir SQL
-- sorgusu atmak "0 Resmon" disiplinini ihlal ederdi -- bu yüzden ayrı,
-- düşük frekanslı bir thread'de önbelleklenir.
local cachedGangTrust = (Config.Supplier and Config.Supplier.DefaultTrust) or 0.5


local function RefreshGangTrust()
    local ok, rows = pcall(function()
        return MySQL.query.await('SELECT AVG(trust) AS avg_trust FROM matrix_supplier_trust', {})
    end)
    local avg = ok and rows and rows[1] and tonumber(rows[1].avg_trust)
    if avg then
        cachedGangTrust = Matrix.Clamp(avg, 0.0, 1.0)
    end
end


CreateThread(function()
    -- İlk okuma: sunucu açılışında bir kere hemen çalışır (LoadFleet/
    -- LoadTrust İLE AYNI "async ilk yükleme" deseni), ardından periyodik.
    local ok, err = pcall(RefreshGangTrust)
    if not ok then
        Matrix.Log('KITCHEN', '[HATA] RefreshGangTrust ilk yukleme basarisiz (yutuldu): %s', tostring(err))
    end
    while true do
        Wait(Config.Kitchen.GangTrustRefreshIntervalMs or 60000)
        local tickOk, tickErr = pcall(RefreshGangTrust)
        if not tickOk then
            Matrix.Log('KITCHEN', '[HATA] RefreshGangTrust hata verdi (yutuldu): %s', tostring(tickErr))
        end
    end
end)


--- Salt-okunur getter — client/hud.lua veya başka bir modül çete güvenini
--- (RAM önbellekten, DB round-trip OLMADAN) okumak isterse.
function Matrix.Kitchen.GetGangTrust()
    return cachedGangTrust
end


--- Trap house'un ortak deposundan (matrix_trap_stash_<id>) deterministik
--- olarak `theftGrams` kadar ürün (Config.Kitchen.Packaging.RawItem VEYA
--- Products listesindeki paketler) çeker -- PackageBatch'in (yukarıda)
--- "en düşük slot numarası önce" tüketim sırasıyla AYNI disiplin. Gerçekte
--- çalınan miktarı (talep edilenden az olabilir -- depo yetersizse) döner.
local function StealFromTrapStash(theftGrams, trapHouseId)
    if theftGrams <= 0.0 then return 0.0 end


    local stashId = ('matrix_trap_stash_%d'):format(trapHouseId)
    local invOk, inv = pcall(function() return exports['ox_inventory']:GetInventory(stashId) end)
    if not invOk or type(inv) ~= 'table' or type(inv.items) ~= 'table' then return 0.0 end


    local candidates = {}
    for slot, item in pairs(inv.items) do
        if type(item) == 'table' and type(item.name) == 'string' and (tonumber(item.count) or 0) > 0 then
            local isTargetable = (item.name == Config.Kitchen.Packaging.RawItem)
            if not isTargetable then
                for _, product in ipairs(Config.Kitchen.Packaging.Products) do
                    if product.item == item.name then isTargetable = true break end
                end
            end
            if isTargetable then
                candidates[#candidates + 1] = { slot = slot, name = item.name, count = tonumber(item.count) or 0 }
            end
        end
    end
    if #candidates == 0 then return 0.0 end
    table.sort(candidates, function(a, b) return a.slot < b.slot end)


    local stolen = 0.0
    for _, c in ipairs(candidates) do
        if stolen >= theftGrams then break end
        local take = math.min(c.count, theftGrams - stolen)
        if take > 0 then
            -- ★ CRITICAL FIX: pcall yalnizca Lua hatasi olup olmadigini
            -- soyler -- RemoveItem'in GERCEK basari boolean'i (2. donus
            -- degeri) AYRICA katı bir guard olarak kontrol edilmeden
            -- `stolen` sisirilirse, esya envanterden hic cikmadigi halde
            -- "calindi" sayilir (sisirilmis stolen degeri).
            local removeOk, removed = pcall(function()
                return exports['ox_inventory']:RemoveItem(stashId, c.name, take, nil, c.slot)
            end)
            if removeOk and removed == true then stolen = stolen + take end
        end
    end
    return stolen
end


-- FORMÜL (RNG YOK, saf eşik karşılaştırması):
--   cetenin genel guveni (cachedGangTrust) > TrustWithdrawalTheftTrustCeiling
--     -> mekanizma SILAHSIZ, hicbir sey olmaz (cete hala guveniliyor).
--   bot.biology.withdrawal_index < TheftWithdrawalThreshold (MEVCUT sabit)
--     -> bot henuz tam yoksunluk krizinde degil, calmaz.
--   Her ikisi de esik disindaysa: theftGrams = addiction_level *
--     TheftGramsPerAddictionPoint (ProcessCook'un AYNI formulu) kadar depodan
--     cekilir; basariliysa loyalty_base TrustWithdrawalLoyaltyPenalty kadar duser.
function Matrix.Kitchen.ProcessTrustWithdrawalTheft(bot)
    if not bot or not bot.state or not bot.biology or not bot.psychology then return end
    if not bot.state.trap_house_id then return end


    local trustCeiling = Config.Kitchen.TrustWithdrawalTheftTrustCeiling or 0.35
    if cachedGangTrust > trustCeiling then return end

    if (bot.biology.withdrawal_index or 0.0) < Config.Kitchen.TheftWithdrawalThreshold then return end

    local trapHouseId = bot.state.trap_house_id
    local theftGrams   = (bot.biology.addiction_level or 0.0) * Config.Kitchen.TheftGramsPerAddictionPoint
    if theftGrams <= 0.0 then return end

    local stolenGrams = StealFromTrapStash(theftGrams, trapHouseId)
    if stolenGrams <= 0.0 then return end

    bot.psychology.loyalty_base = Matrix.Clamp(
        bot.psychology.loyalty_base - (Config.Kitchen.TrustWithdrawalLoyaltyPenalty or 0.10), 0.0, 1.0)
    Matrix.MarkBotDirty(bot.id)

    -- Yalnızca log/flavor amaçlı tahmini rakam -- HİÇBİR ekonomi havuzuna
    -- (Matrix.CashDecay dahil) YATIRILMAZ; oyuncunun kartelinden KALICI kayıp.
    local estimatedStreetValue = stolenGrams * (Config.Market.StreetBasePricePerGram or 20.0)

    Matrix.Log('KITCHEN',
        '[ICTEN HIRSIZLIK: CETE GUVENI COKTU] Bot #%d (%s) trap #%d deposundan %.1fg calip sokakta kendi hesabina sattı ' ..
        '(cete-guveni:%.3f/%.2f, yoksunluk:%.3f, yeni sadakat:%.3f, tahmini kayip:$%.0f).',
        bot.id, bot.dna_id, trapHouseId, stolenGrams,
        cachedGangTrust, trustCeiling, bot.biology.withdrawal_index, bot.psychology.loyalty_base, estimatedStreetValue)
end


-- =====================================================================
-- ★★★ FAZ 6 - ADIM 2: ENDÜSTRİYEL BOTANİK OTOMASYONU & GURME KANALLAR ★★★
-- =====================================================================
-- Bu blok TAMAMEN YENİ bir EKLEMEDİR. ProcessMinuteCycle'ın (yukarıda)
-- HİÇBİR formülüne dokunulmadı — tek istisna, o fonksiyonun BAŞINA eklenen
-- tek satırlık `ProcessBotanyCycle()` çağrısıdır (bkz. o fonksiyonun
-- güncellenmiş hali). Evde üretim ANA GELİR KAPISI DEĞİL, "Gurme Destek"
-- KATMANIDIR: masterpiece_gourmet_weed, sevk/torbacılık döngülerinde
-- sokak taban fiyatına TAM 3.0x çarpan uygular; trash_weed satılamaz.
--
-- SIFIR RNG: büyüme, pH/rüzgar sapması, hasat kalitesi ve koku sızıntısı
-- tamamen eşik karşılaştırması + doğrusal formüllerle ilerler.
-- SIFIR EK THREAD: botanik döngüsü, mevcut per-bot ProcessMinuteCycle
-- içinden bir "minute bucket" kapısıyla çağrılır; N bot için N kez
-- çağrılsa bile gerçek iş dakikada yalnızca BİR kez yapılır (0 Resmon).
-- =====================================================================

-- RAM önbellek (matrix_botany_cabinets): trap_house_id -> cabinet state.
-- Diskte tutulur ama döngü RAM üzerinden çalışır (BallisticCache/
-- PolicePersonalityCache/Hubs İLE AYNI "yükle-sonra-periyodik-senkronize et"
-- deseni).
local BotanyCabinetCache = {}          -- [trapHouseId] = cabinet
local _BotanyLastBucket  = -1          -- global minute-bucket kapısı
local _BotanyLastSyncBucket = -1       -- DB persist kapısı (her dk 1 kez)


-- ─────────────────────────────────────────────────────────────────────
-- ADIM 1: DATABASE MIGRATION (ADDITIVE, IF NOT EXISTS)
-- ─────────────────────────────────────────────────────────────────────
CreateThread(function()
    local migOk, migErr = pcall(function()
        MySQL.query.await([[
            CREATE TABLE IF NOT EXISTS matrix_botany_cabinets (
                trap_house_id INT PRIMARY KEY,
                plant_stage INT DEFAULT 0,
                plant_ph FLOAT DEFAULT 6.0,
                wind_speed FLOAT DEFAULT 0.0,
                carbon_filter_life FLOAT DEFAULT 1.00,
                growth_progress FLOAT DEFAULT 0.00,
                status VARCHAR(24) DEFAULT 'idle'
            )
        ]], {})
    end)
    if not migOk then
        Matrix.Log('KITCHEN',
            '[MATRIX:INDUSTRIAL_BOTANY_PHASE6] Migration hatasi (yutuldu): %s', tostring(migErr))
        return
    end

    -- İlk yükleme: RAM önbelleğini DB'den doldur.
    local loadOk, rows = pcall(function()
        return MySQL.query.await('SELECT * FROM matrix_botany_cabinets', {})
    end)
    if loadOk and type(rows) == 'table' then
        for _, row in ipairs(rows) do
            BotanyCabinetCache[row.trap_house_id] = {
                trap_house_id                    = tonumber(row.trap_house_id),
                plant_stage                      = tonumber(row.plant_stage) or 0,
                plant_ph                         = tonumber(row.plant_ph) or 6.0,
                wind_speed                       = tonumber(row.wind_speed) or 0.0,
                carbon_filter_life               = tonumber(row.carbon_filter_life) or 1.0,
                growth_progress                  = tonumber(row.growth_progress) or 0.0,
                status                           = row.status or 'idle',
                -- Yeni RAM-alanları (persist EDİLMEZ, restart'ta yeniden kurulur):
                last_odor_alert_hour_bucket      = -1,
                stagnation_ticks                 = 0,
                total_growth_ticks               = 0,
                perfect_conditions_this_growth   = true,
            }
        end
    end
    Matrix.Log('KITCHEN',
        '[MATRIX:INDUSTRIAL_BOTANY_PHASE6] Botanik matrisi yuklendi: %d kabin.',
        (function() local n=0 for _ in pairs(BotanyCabinetCache) do n=n+1 end return n end)())
end)


-- ─────────────────────────────────────────────────────────────────────
-- YARDIMCI: deterministik "özellik kimyager botu" seçimi.
-- Yüksek skill_chemistry, eşitlikte düşük ID (FindCleanBotAtTrapHouse İLE
-- AYNI deterministik seçim disiplini). RNG yok.
-- ─────────────────────────────────────────────────────────────────────
local function FindPropertyChemistBot(trapHouseId)
    local foundId, foundBot, bestSkill = nil, nil, -1.0
    for id, b in pairs(Matrix.Bots) do
        if b.status == 'active' and b.state and b.state.trap_house_id == trapHouseId
            and b.psychology then
            local skill = tonumber(b.psychology.skill_chemistry) or 0.0
            if skill > bestSkill or (skill == bestSkill and (not foundId or id < foundId)) then
                foundId, foundBot, bestSkill = id, b, skill
            end
        end
    end
    return foundId, foundBot
end


-- ─────────────────────────────────────────────────────────────────────
-- YARDIMCI: pH/rüzgar penceresi + koku sızıntısı formülleri (SAF, test
-- edilebilir; diagnostics bunları doğrudan çağırır).
-- ─────────────────────────────────────────────────────────────────────
local function BotanyIsStagnant(plantPh, windSpeed)
    local B = Config.Kitchen.Botany or {}
    local phMin = B.OptimalPHMin or 5.8
    local phMax = B.OptimalPHMax or 6.2
    local windMin = B.WindSpeedMinimum or 1.5
    if plantPh < phMin or plantPh > phMax then return true end
    if windSpeed < windMin then return true end
    return false
end


--- Koku sızıntısı formülü (SAF):
---   odor_leak_intensity = (plant_stage * 1.25) - (carbon_filter_life * 4.0)
--- Dönüş: intensity, triggers (>2.0)
function Matrix.Kitchen.TestOdorLeak(plantStage, carbonFilterLife)
    local intensity = (plantStage * 1.25) - (carbonFilterLife * 4.0)
    return intensity, intensity > 2.0
end


--- Hasat sonucu değerlendirme (SAF):
---   coefficient >= 0.75 VE perfectConditions -> masterpiece (1 adet)
---   coefficient < 0.35 VEYA heavyStagnation   -> trash_weed (10 adet)
---   aksi halde                                 -> normal ham parti (50g)
--- Dönüş: itemName, count
function Matrix.Kitchen.TestBotanyHarvest(coefficient, perfectConditions, heavyStagnation)
    local B = Config.Kitchen.Botany or {}
    local masterThr = B.MasterpieceCoefficientThreshold or 0.75
    local trashThr  = B.TrashCoefficientThreshold       or 0.35
    local trashCnt  = B.TrashWeedSpawnCount             or 10

    if coefficient >= masterThr and perfectConditions == true then
        return 'masterpiece_gourmet_weed', 1
    elseif coefficient < trashThr or heavyStagnation == true then
        return 'trash_weed', trashCnt
    else
        return (Config.Kitchen.Packaging and Config.Kitchen.Packaging.RawItem) or 'weed_raw', 50
    end
end


-- ─────────────────────────────────────────────────────────────────────
-- YARDIMCI: bir cabinet için hasat uygulaması (yan etkili -- envantere
-- yazar; test fonksiyonu YUKARIDA saf versiyonu sağlar).
-- ─────────────────────────────────────────────────────────────────────
local function ApplyBotanyHarvest(cabinet)
    local trapHouseId = cabinet.trap_house_id

    local botId, bot = FindPropertyChemistBot(trapHouseId)
    local coefficient  = 0.0
    if bot then
        local skill      = (bot.psychology and tonumber(bot.psychology.skill_chemistry)) or 0.0
        local withdrawal = (bot.biology    and tonumber(bot.biology.withdrawal_index)) or 0.0
        if withdrawal < 0.0 then withdrawal = 0.0 elseif withdrawal > 1.0 then withdrawal = 1.0 end
        coefficient = skill * (1.0 - withdrawal)
    end

    local heavyStagnation = (cabinet.total_growth_ticks > 0)
        and ((cabinet.stagnation_ticks / cabinet.total_growth_ticks) >= 0.5)

    local itemName, itemCount = Matrix.Kitchen.TestBotanyHarvest(
        coefficient,
        cabinet.perfect_conditions_this_growth == true,
        heavyStagnation
    )

    local stashId = ('matrix_trap_stash_%d'):format(trapHouseId)
    local house = Matrix.TrapHouses and Matrix.TrapHouses[trapHouseId]
    local stashLabel = (house and house.label and ('%s Deposu'):format(house.label))
        or ('Trap House #%d Deposu'):format(trapHouseId)

    pcall(function()
        exports['ox_inventory']:RegisterStash(stashId, stashLabel, 100, 200000)
    end)

    local metadata = {
        botany_quality_coefficient = coefficient,
        stagnation_ratio           = (cabinet.total_growth_ticks > 0)
            and (cabinet.stagnation_ticks / cabinet.total_growth_ticks) or 0.0,
        perfect_conditions         = cabinet.perfect_conditions_this_growth == true,
        grown_by_bot               = botId,
    }

    if itemName == 'masterpiece_gourmet_weed' then
        metadata.multiplier = (Config.Kitchen.Botany and Config.Kitchen.Botany.MasterpieceMultiplier) or 3.0
        metadata.purity     = 1.0
        pcall(function()
            exports['ox_inventory']:AddItem(stashId, 'masterpiece_gourmet_weed', itemCount, metadata)
        end)
        Matrix.Log('KITCHEN',
            '[MATRIX:INDUSTRIAL_BOTANY_PHASE6] Trap #%d MÜKEMMEL HASAT: %dx masterpiece_gourmet_weed (katsayi=%.3f, 3.0x sokak carpani).',
            trapHouseId, itemCount, coefficient)
    elseif itemName == 'trash_weed' then
        pcall(function()
            exports['ox_inventory']:AddItem(stashId, 'trash_weed', itemCount, metadata)
        end)
        Matrix.Log('KITCHEN',
            '[MATRIX:INDUSTRIAL_BOTANY_PHASE6] Trap #%d ÇÖPE GİTTİ: %dx trash_weed (katsayi=%.3f, stagnation=%s).',
            trapHouseId, itemCount, coefficient, tostring(heavyStagnation))
    else
        pcall(function()
            exports['ox_inventory']:AddItem(stashId, itemName, itemCount, { purity = coefficient })
        end)
        Matrix.Log('KITCHEN',
            '[MATRIX:INDUSTRIAL_BOTANY_PHASE6] Trap #%d normal hasat: %dg %s (katsayi=%.3f).',
            trapHouseId, itemCount, itemName, coefficient)
    end
end


-- ─────────────────────────────────────────────────────────────────────
-- YARDIMCI: matrix_bureau_intensity ConVar'a +0.50 adım sıçraması.
-- ConVar string tutar (GetConvar/SetConvar); kayan nokta hassasiyeti
-- kaybolmasın diye tonumber/tostring round-trip edilir.
-- ─────────────────────────────────────────────────────────────────────
local function BumpBureauIntensityConVar(stepAmount)
    local raw = GetConvar and GetConvar('matrix_bureau_intensity', '0.0') or '0.0'
    local cur = tonumber(raw) or 0.0
    local nxt = cur + (stepAmount or 0.50)
    if SetConvar then
        SetConvar('matrix_bureau_intensity', ('%.4f'):format(nxt))
    end
    return cur, nxt
end


-- ─────────────────────────────────────────────────────────────────────
-- YARDIMCI: koku sızıntısı + LSPD K9 ihbar adımı (her 60 dakikada bir kez).
-- Sadece saf formülü uygular; ConVar'a yazım için BumpBureauIntensityConVar
-- kullanılır.
-- ─────────────────────────────────────────────────────────────────────
local function ProcessOdorLeakForCabinet(cabinet, hourBucket)
    local stage   = cabinet.plant_stage or 0
    local filter  = cabinet.carbon_filter_life or 0.0
    if stage < 1 or stage > 4 then return end

    local intensity, triggers = Matrix.Kitchen.TestOdorLeak(stage, filter)
    if not triggers then return end

    if cabinet.last_odor_alert_hour_bucket == hourBucket then return end
    cabinet.last_odor_alert_hour_bucket = hourBucket

    local cur, nxt = BumpBureauIntensityConVar(0.50)
    Matrix.Log('KITCHEN',
        '[MATRIX:INDUSTRIAL_BOTANY_PHASE6] LSPD K9 KOKU ALARMI: Trap #%d stage=%d intensity=%.3f > 2.0 -> matrix_bureau_intensity %.3f -> %.3f (+0.50 step).',
        cabinet.trap_house_id, stage, intensity, cur, nxt)
end


-- ─────────────────────────────────────────────────────────────────────
-- YARDIMCI: tek bir cabinet için tam dakika döngüsü.
--   1) pH / rüzgar → stagnation bayrağı
--   2) growth_progress += base * (1.0 veya StagnationFactor)
--   3) carbon_filter_life degradasyonu
--   4) plant_stage türetimi (0 → 1..4)
--   5) koku sızıntısı kontrolü
--   6) growth >= 100 → hasat + reset
-- SIFIR RNG; tüm kararlar eşik ve doğrusal formül.
-- ─────────────────────────────────────────────────────────────────────
local function ProcessCabinetMinute(cabinet, hourBucket)
    if cabinet.status ~= 'growing' then return end

    local B = Config.Kitchen.Botany or {}
    local baseGrowth          = B.BaseGrowthPerMinute       or 0.50
    local stagnFactor         = B.StagnationFactor          or 0.50
    local filterDecayPerMin   = B.CarbonFilterDecayPerMin   or 0.0015

    -- 1) Biyokimyasal sürtünme
    local stagnant = BotanyIsStagnant(cabinet.plant_ph, cabinet.wind_speed)
    cabinet.total_growth_ticks = (cabinet.total_growth_ticks or 0) + 1
    if stagnant then
        cabinet.stagnation_ticks = (cabinet.stagnation_ticks or 0) + 1
        cabinet.perfect_conditions_this_growth = false
    end

    -- 2) Büyüme momentumu (stagnasyon -> -0.50 kat faktör)
    local delta = baseGrowth * (stagnant and (1.0 - stagnFactor) or 1.0)
    cabinet.growth_progress = Matrix.Clamp((cabinet.growth_progress or 0.0) + delta, 0.0, 100.0)

    -- 3) Karbon filtre ömrü zamanla düşer (0.0 tabanına kilitli)
    cabinet.carbon_filter_life = math.max((cabinet.carbon_filter_life or 0.0) - filterDecayPerMin, 0.0)

    -- 4) Aşama türetimi (0.0 -> 1; 25 -> 2; 50 -> 3; 75 -> 4). Deterministik
    --    eşik karşılaştırmaları (RNG yok).
    local g = cabinet.growth_progress
    local newStage = 0
    if     g >= 75.0 then newStage = 4
    elseif g >= 50.0 then newStage = 3
    elseif g >= 25.0 then newStage = 2
    elseif g >  0.0  then newStage = 1
    end
    cabinet.plant_stage = newStage

    -- 5) Koku sızıntısı (her 60 dk'da bir adım sıçraması)
    ProcessOdorLeakForCabinet(cabinet, hourBucket)

    -- 6) Hasat (growth >= 100.0)
    if cabinet.growth_progress >= 100.0 then
        ApplyBotanyHarvest(cabinet)
        -- Reset: sıfırdan yeni bir parti için hazır (idle). Yeni parti
        -- başlatmak için /botanikbaslat kullanılır.
        cabinet.plant_stage                   = 0
        cabinet.growth_progress               = 0.0
        cabinet.status                        = 'idle'
        cabinet.stagnation_ticks              = 0
        cabinet.total_growth_ticks            = 0
        cabinet.perfect_conditions_this_growth = true
    end
end


-- ─────────────────────────────────────────────────────────────────────
-- ANA BOTANİK DÖNGÜSÜ: ProcessMinuteCycle tarafından her bot için çağrılır
-- ancak "minute bucket" kapısı sayesinde gerçek iş DAKİKADA YALNIZCA BİR
-- KEZ yapılır (0 Resmon). Tüm mevcut kabinler taranır.
-- ─────────────────────────────────────────────────────────────────────
function Matrix.Kitchen.ProcessBotanyCycle()
    local now = Matrix.Now()
    local bucket = math.floor(now / 60)
    if bucket == _BotanyLastBucket then return end
    _BotanyLastBucket = bucket

    local hourBucket = math.floor(now / 3600)

    for _, cabinet in pairs(BotanyCabinetCache) do
        ProcessCabinetMinute(cabinet, hourBucket)
    end

    -- Dakikada bir kez DB persist (dirty write gate: sadece bucket değişince).
    if bucket ~= _BotanyLastSyncBucket then
        _BotanyLastSyncBucket = bucket
        local persistOk, persistErr = pcall(function()
            for _, cabinet in pairs(BotanyCabinetCache) do
                MySQL.query.await([[
                    INSERT INTO matrix_botany_cabinets
                        (trap_house_id, plant_stage, plant_ph, wind_speed, carbon_filter_life, growth_progress, status)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON DUPLICATE KEY UPDATE
                        plant_stage = VALUES(plant_stage),
                        plant_ph = VALUES(plant_ph),
                        wind_speed = VALUES(wind_speed),
                        carbon_filter_life = VALUES(carbon_filter_life),
                        growth_progress = VALUES(growth_progress),
                        status = VALUES(status)
                ]], {
                    cabinet.trap_house_id, cabinet.plant_stage, cabinet.plant_ph,
                    cabinet.wind_speed, cabinet.carbon_filter_life, cabinet.growth_progress,
                    cabinet.status
                })
            end
        end)
        if not persistOk then
            Matrix.Log('KITCHEN',
                '[MATRIX:INDUSTRIAL_BOTANY_PHASE6] Persist hatasi (yutuldu): %s', tostring(persistErr))
        end
    end
end


-- ─────────────────────────────────────────────────────────────────────
-- KABİN BAŞLATMA / AYAR API'si (event-tetiklemeli; master ticker'ı
-- bloklamaz). Deterministik; RNG yok.
-- ─────────────────────────────────────────────────────────────────────
function Matrix.Kitchen.StartBotanyCabinet(trapHouseId, initialPh, initialWind, carbonFilterLife)
    trapHouseId = tonumber(trapHouseId)
    if not trapHouseId or not Matrix.TrapHouses or not Matrix.TrapHouses[trapHouseId] then
        return nil, 'bad_trap_house'
    end

    local cabinet = BotanyCabinetCache[trapHouseId]
    if not cabinet then
        cabinet = {
            trap_house_id                    = trapHouseId,
            plant_stage                      = 0,
            plant_ph                         = 6.0,
            wind_speed                       = 0.0,
            carbon_filter_life               = 1.0,
            growth_progress                  = 0.0,
            status                           = 'idle',
            last_odor_alert_hour_bucket      = -1,
            stagnation_ticks                 = 0,
            total_growth_ticks               = 0,
            perfect_conditions_this_growth   = true,
        }
        BotanyCabinetCache[trapHouseId] = cabinet
    end

    cabinet.plant_ph           = tonumber(initialPh)           or 6.0
    cabinet.wind_speed         = tonumber(initialWind)         or 0.0
    cabinet.carbon_filter_life = tonumber(carbonFilterLife)    or 1.0
    cabinet.growth_progress    = 0.0
    cabinet.plant_stage        = 0
    cabinet.status             = 'growing'
    cabinet.stagnation_ticks   = 0
    cabinet.total_growth_ticks = 0
    cabinet.perfect_conditions_this_growth = true

    Matrix.Log('KITCHEN',
        '[MATRIX:INDUSTRIAL_BOTANY_PHASE6] Trap #%d botanik kabini baslatildi (pH=%.2f, ruzgar=%.2f, filtre=%.2f).',
        trapHouseId, cabinet.plant_ph, cabinet.wind_speed, cabinet.carbon_filter_life)
    return cabinet
end


function Matrix.Kitchen.GetBotanyCabinet(trapHouseId)
    return BotanyCabinetCache[tonumber(trapHouseId)]
end


function Matrix.Kitchen.SetBotanyEnvironment(trapHouseId, ph, wind, filterLife)
    local cabinet = BotanyCabinetCache[tonumber(trapHouseId)]
    if not cabinet then return nil, 'no_cabinet' end
    if ph         ~= nil then cabinet.plant_ph           = tonumber(ph)         or cabinet.plant_ph end
    if wind       ~= nil then cabinet.wind_speed         = tonumber(wind)       or cabinet.wind_speed end
    if filterLife ~= nil then cabinet.carbon_filter_life = tonumber(filterLife) or cabinet.carbon_filter_life end
    return cabinet
end


-- ─────────────────────────────────────────────────────────────────────
-- Tani / Regresyon API'si: server/matrix_diagnostics.lua'nın
-- RegisterCheck varsa buraya bağlanır; yoksa en azından exports ile
-- dışarı açılır ve sunucu açılışında kendi kendini doğrular.
--
-- ★ [MATRIX:PHARMACOLOGICAL_DILUTION_CORE] Bu blok 3. regresyonu içerir:
--   farmakolojik seyreltme çekirdeğinin C1*V1 = C2*V2 yasasını
--   doğrulayan saf matematik testi (RNG yok, envanter yan etkisi yok).
-- ─────────────────────────────────────────────────────────────────────
local function RunBotanyRegressionChecks()
    local results = {}

    -- 1) 0.25 chemist coefficient -> tam 10x trash_weed
    do
        local item, count = Matrix.Kitchen.TestBotanyHarvest(0.25, true, false)
        local pass = (item == 'trash_weed') and (count == 10)
        results[#results + 1] = {
            name = 'botany_trash_outcome_0_25',
            pass = pass,
            detail = ('item=%s count=%d (beklenen: trash_weed/10)'):format(tostring(item), count),
        }
    end

    -- 2) Filtresiz (carbon_filter_life=0) Stage 4 -> intensity 5.0 > 2.0
    do
        local intensity, triggers = Matrix.Kitchen.TestOdorLeak(4, 0.0)
        local pass = (triggers == true) and (intensity > 2.0)
        results[#results + 1] = {
            name = 'botany_odor_leak_stage4_unfiltered',
            pass = pass,
            detail = ('intensity=%.3f triggers=%s (beklenen: >2.0/true)'):format(intensity, tostring(triggers)),
        }
    end

    -- 3) ★ [MATRIX:PHARMACOLOGICAL_DILUTION_CORE] Farmakolojik seyreltme
    --    çekirdeği: rawWeight = agentWeight = X ise, V_total = 2X ve
    --    C2_ideal = (X*rawPurity)/(2X) = rawPurity/2 OLMALI (C1*V1=C2*V2
    --    yasasının doğrudan sonucu). İnsani hata terimleri nötrlendiğinde
    --    (skill=1, fatigue=0, cortisol=0 -> error_coefficient=0),
    --    final_output_purity = C2_ideal ile birebir eşit olmalı.
    do
        local pass = true
        local detailParts = {}

        -- Senaryo A: 100g/0.80 saflık + 100g kesme ajanı -> C2_ideal = 0.40
        local a = Matrix.Kitchen.ComputePharmacologicalDilution(100.0, 0.80, 100.0, 1.0, 0.0, 0.0)
        local okA = (math.abs(a.theoretical_purity - 0.40) < 1e-9)
                and (math.abs(a.output_purity - 0.40) < 1e-9)
                and (math.abs(a.error_coefficient) < 1e-9)
                and (a.molecular_saturation == false)
        if not okA then pass = false end
        detailParts[#detailParts + 1] = ('A(100g/0.80 + 100g ajan): C2=%.6f out=%.6f err=%.6f')
            :format(a.theoretical_purity, a.output_purity, a.error_coefficient)

        -- Senaryo B: 200g/0.60 saflık + 200g kesme ajanı -> C2_ideal = 0.30
        local b = Matrix.Kitchen.ComputePharmacologicalDilution(200.0, 0.60, 200.0, 1.0, 0.0, 0.0)
        local okB = (math.abs(b.theoretical_purity - 0.30) < 1e-9)
                and (math.abs(b.output_purity - 0.30) < 1e-9)
        if not okB then pass = false end
        detailParts[#detailParts + 1] = ('B(200g/0.60 + 200g ajan): C2=%.6f out=%.6f')
            :format(b.theoretical_purity, b.output_purity)

        results[#results + 1] = {
            name = 'pharmacological_dilution_half_purity_equal_mass',
            pass = pass,
            detail = table.concat(detailParts, ' | '),
        }
    end

    for _, r in ipairs(results) do
        Matrix.Log('KITCHEN',
            '[MATRIX:PHARMACOLOGICAL_DILUTION_CORE] REGRESYON %s -> %s (%s)',
            r.name, r.pass and 'PASS' or 'FAIL', r.detail)
    end

    return results
end


exports('BotanyRunRegression', function()
    return RunBotanyRegressionChecks()
end)


exports('BotanyStartCabinet', function(trapHouseId, ph, wind, filterLife)
    return Matrix.Kitchen.StartBotanyCabinet(trapHouseId, ph, wind, filterLife)
end)


exports('BotanyGetCabinet', function(trapHouseId)
    return Matrix.Kitchen.GetBotanyCabinet(trapHouseId)
end)


-- Tani framework'ü mevcutsa (server/matrix_diagnostics.lua) kayıt ol;
-- yoksa en azından bir kere kendi kendini koştur (konsola PASS/FAIL
-- etiketli log basar, hiçbir zaman throw etmez).
--
-- ★ [MATRIX:PHARMACOLOGICAL_DILUTION_CORE] 3. yeni regresyon testi
-- Diagnostics framework'üne kaydediliyor (142 -> 143).
CreateThread(function()
    Wait(2000)
    if Matrix.Diagnostics and type(Matrix.Diagnostics.RegisterCheck) == 'function' then
        local function check1()
            local item, count = Matrix.Kitchen.TestBotanyHarvest(0.25, true, false)
            return (item == 'trash_weed') and (count == 10)
        end
        local function check2()
            local intensity, triggers = Matrix.Kitchen.TestOdorLeak(4, 0.0)
            return (triggers == true) and (intensity > 2.0)
        end
        local function check3()
            -- ★ [MATRIX:PHARMACOLOGICAL_DILUTION_CORE] Eşit kütlelerde ham
            -- madde ve kesme ajanı, ideal saflığı TAM YARILAR (C1*V1=C2*V2).
            -- İnsani hata sıfırlandığında çıkış saflığı C2_ideal'e eşit
            -- kalmalı -- saf matematik, envanter yan etkisi YOK.
            local a = Matrix.Kitchen.ComputePharmacologicalDilution(100.0, 0.80, 100.0, 1.0, 0.0, 0.0)
            if math.abs(a.theoretical_purity - 0.40) >= 1e-9 then return false end
            if math.abs(a.output_purity      - 0.40) >= 1e-9 then return false end
            if a.molecular_saturation ~= false then return false end

            local b = Matrix.Kitchen.ComputePharmacologicalDilution(200.0, 0.60, 200.0, 1.0, 0.0, 0.0)
            if math.abs(b.theoretical_purity - 0.30) >= 1e-9 then return false end
            if math.abs(b.output_purity      - 0.30) >= 1e-9 then return false end
            return true
        end
        pcall(function() Matrix.Diagnostics.RegisterCheck('botany_trash_outcome_0_25', check1) end)
        pcall(function() Matrix.Diagnostics.RegisterCheck('botany_odor_leak_stage4_unfiltered', check2) end)
        pcall(function() Matrix.Diagnostics.RegisterCheck('pharmacological_dilution_half_purity_equal_mass', check3) end)
        Matrix.Log('KITCHEN',
            '[MATRIX:PHARMACOLOGICAL_DILUTION_CORE] 3 regresyon testi Diagnostics framework une kaydedildi (143/143).')
    else
        -- Diagnostics framework yoksa bile kendi kendine doğrula (no-op).
        RunBotanyRegressionChecks()
    end
end)


-- =====================================================================
-- MONOKROM TAKTİK DEBUG PANELİ (herkese açık test grubu, restricted=false)
-- Gerçek oyun temposu: fatigue/cortisol her GERÇEK dakikada bir
-- (ProcessMinuteCycle), withdrawal her GERÇEK saatte bir (ProcessHourCycle)
-- işlenir. Bu komutlar o beklemeyi atlayıp döngüleri anlık tetikler.
-- =====================================================================
local function Reply(src, msg)
    if type(src) == 'number' and src > 0 then
        TriggerClientEvent('chat:addMessage', src, { args = { '[KITCHEN]', msg } })
    else
        print(('[MATRIX:KITCHEN:CONSOLE] %s'):format(msg))
    end
end


-- /mutfaktest [botId] [trapHouseId] [hamAgirlik] [hamSaflik] [ajanAgirlik] -
-- ProcessCook'u bir BOT aktörü için doğrudan çalıştırır (normal event
-- köprüsü sadece 'player' aktörünü destekler). theoretical_purity/
-- error_coefficient/output_purity formüllerini bot skill/fatigue/cortisol
-- değerleriyle test eder. trapHouseId GERÇEKTEN var olmalı (matrix_kitchen_
-- batches.trap_house_id -> matrix_trap_houses FK constraint'i nedeniyle).
RegisterCommand('mutfaktest', function(src, args)
    -- ★ v6.6.4-A2d: fail-closed yetki kapısı
    if type(src) == 'number' and src > 0 and not KitchenHasCommandAuthority(src) then
        Reply(src, 'Yetkisiz.'); return
    end
    local botId = tonumber(args[1])
    local trapHouseId = tonumber(args[2])
    local rawWeight  = tonumber(args[3]) or 100.0
    local rawPurity  = tonumber(args[4]) or 0.8
    local agentWeight= tonumber(args[5]) or 50.0
    if not botId or not Matrix.Bots[botId] or not trapHouseId or not Matrix.TrapHouses[trapHouseId] then
        Reply(src, 'Kullanim: /mutfaktest [botId] [trapHouseId (gerçek olmalı)] [hamAgirlik] [hamSaflik] [ajanAgirlik]'); return
    end


    local result = Matrix.Kitchen.ProcessCook({ kind = 'bot', id = botId }, trapHouseId, rawWeight, rawPurity, agentWeight)
    if not result then Reply(src, 'Test başarısız.'); return end


    Reply(src, ('Teorik:%.3f Hata:%.3f Çıkış-Saflık:%.3f Çalıntı:%.1fg Rakip-Sızma:%s Doyum:%s'):format(
        result.theoretical_purity, result.error_coefficient, result.output_purity,
        result.theft_amount, tostring(result.rival_infiltration), tostring(result.molecular_saturation)))
end, false)


-- /dakikadongusu [botId] - ProcessMinuteCycle'ı 60sn beklemeden anlık çalıştırır.
RegisterCommand('dakikadongusu', function(src, args)
    local botId = tonumber(args[1])
    local bot = botId and Matrix.Bots[botId]
    if not bot then Reply(src, 'Kullanim: /dakikadongusu [botId]'); return end


    Matrix.Kitchen.ProcessMinuteCycle(bot)
    Reply(src, ('Bot #%d dakika döngüsü çalıştı. Yorgunluk:%.3f Kortizol:%.3f Chem:%.3f'):format(
        botId, bot.biology.fatigue_level, bot.biology.cortisol_level, bot.psychology.skill_chemistry))
end, false)


-- /saatdongusu [botId] - ProcessHourCycle'ı 3600sn beklemeden anlık çalıştırır.
RegisterCommand('saatdongusu', function(src, args)
    local botId = tonumber(args[1])
    local bot = botId and Matrix.Bots[botId]
    if not bot then Reply(src, 'Kullanim: /saatdongusu [botId]'); return end


    Matrix.Kitchen.ProcessHourCycle(bot)
    Reply(src, ('Bot #%d saat döngüsü çalıştı. Yoksunluk:%.3f'):format(botId, bot.biology.withdrawal_index))
end, false)


-- /yakalatest [botId] [trapHouseId] - OnCaptured'ı (I_snitch formülü) doğrudan
-- tetikler; normalde bir baskın/çatışma sonrası dolaylı çağrılır. trapHouseId
-- GERÇEKTEN var olmalı (matrix_snitch_events'in FK constraint'i nedeniyle).
RegisterCommand('yakalatest', function(src, args)
    local botId = tonumber(args[1])
    local trapHouseId = tonumber(args[2])
    if not botId or not Matrix.Bots[botId] or not trapHouseId or not Matrix.TrapHouses[trapHouseId] then
        Reply(src, 'Kullanim: /yakalatest [botId] [trapHouseId (gerçek olmalı)]'); return
    end


    local snitchIndex, didSnitch = Matrix.Kitchen.OnCaptured(botId, trapHouseId)
    Reply(src, ('Bot #%d yakalandı. I_snitch=%.3f İhbar:%s'):format(botId, snitchIndex, tostring(didSnitch)))
end, false)


-- /kortizolsicramasi [botId] [gunshot|bureau_vehicle] - AdjustCortisol'ı bir
-- BOTA uygular (main.lua'daki /kortizoltetikle sadece çağıran oyuncuyu hedefler).
RegisterCommand('kortizolsicramasi', function(src, args)
    local botId = tonumber(args[1])
    local spikeType = args[2] or 'gunshot'
    if not botId or not Matrix.Bots[botId] then
        Reply(src, 'Kullanim: /kortizolsicramasi [botId] [gunshot|bureau_vehicle]'); return
    end


    Matrix.Kitchen.AdjustCortisol({ kind = 'bot', id = botId }, spikeType)
    Reply(src, ('Bot #%d kortizol: %.3f'):format(botId, Matrix.Bots[botId].biology.cortisol_level))
end, false)


-- /katmandurum [botId] - matrix_knowledge_mask'i test amacli gosterir.
RegisterCommand('katmandurum', function(src, args)
    local botId = tonumber(args[1])
    if not botId or not Matrix.Bots[botId] then Reply(src, 'Kullanim: /katmandurum [botId]'); return end

    local mask = Matrix.Kitchen.GetKnowledgeMask(botId)
    if not mask then Reply(src, 'Maske hesaplanamadi.'); return end

    local dropCount = 0
    for _ in pairs(mask.known_dead_drops) do dropCount = dropCount + 1 end

    Reply(src, ('Bot #%d (rol:%s) -> Bolge:%s | Ana-Us-Biliyor:%s | Bilinen-Dead-Drop:%d'):format(
        botId, mask.role_snapshot, tostring(mask.zone_id), tostring(mask.knows_main_base), dropCount))
end, false)

-- /katmantemizle [botId] - FlushKatmanKnowledge'i elle tetikler (test/rol
-- degisimi sonrasi manuel temizlik icin).
RegisterCommand('katmantemizle', function(src, args)
    local botId = tonumber(args[1])
    if not botId or not Matrix.Bots[botId] then Reply(src, 'Kullanim: /katmantemizle [botId]'); return end

    Matrix.Kitchen.FlushKatmanKnowledge(botId)
    Reply(src, ('Bot #%d icin katman bilgisi temizlendi ve yeniden kuruldu.'):format(botId))
end, false)


-- ★ FAZ 6 - ADIM 2: Botanik debug komutlari (endüstriyel botanik / gurme).
RegisterCommand('botanikbaslat', function(src, args)
    local trapHouseId = tonumber(args[1])
    local ph       = tonumber(args[2])
    local wind     = tonumber(args[3])
    local filter   = tonumber(args[4])
    if not trapHouseId then
        Reply(src, 'Kullanim: /botanikbaslat [trapHouseId] [pH=6.0] [ruzgar=1.5] [filtre=1.0]'); return
    end

    local cabinet, reason = Matrix.Kitchen.StartBotanyCabinet(trapHouseId, ph, wind, filter)
    if not cabinet then
        Reply(src, ('Botanik kabini baslatilamadi: %s'):format(tostring(reason)))
        return
    end
    Reply(src, ('Trap #%d botanik kabini baslatildi (pH=%.2f, ruzgar=%.2f, filtre=%.2f).'):format(
        trapHouseId, cabinet.plant_ph, cabinet.wind_speed, cabinet.carbon_filter_life))
end, false)


RegisterCommand('botanikdurum', function(src, args)
    local trapHouseId = tonumber(args[1])
    if not trapHouseId then Reply(src, 'Kullanim: /botanikdurum [trapHouseId]'); return end
    local cabinet = Matrix.Kitchen.GetBotanyCabinet(trapHouseId)
    if not cabinet then Reply(src, 'Kabin bulunamadi.'); return end
    local intensity, triggers = Matrix.Kitchen.TestOdorLeak(cabinet.plant_stage, cabinet.carbon_filter_life)
    Reply(src, ('Trap #%d | stage=%d status=%s growth=%.2f/100 pH=%.2f wind=%.2f filtre=%.3f | koku=%.3f (%s)'):format(
        trapHouseId, cabinet.plant_stage, cabinet.status, cabinet.growth_progress,
        cabinet.plant_ph, cabinet.wind_speed, cabinet.carbon_filter_life,
        intensity, triggers and 'ALARM' or 'OK'))
end, false)


RegisterCommand('botanikregresyon', function(src)
    local results = RunBotanyRegressionChecks()
    for _, r in ipairs(results) do
        Reply(src, ('%s -> %s (%s)'):format(r.name, r.pass and 'PASS' or 'FAIL', r.detail))
    end
end, false)


-- ★ [MATRIX:PHARMACOLOGICAL_DILUTION_CORE] Saf farmakolojik seyreltme
-- çekirdeğini (ProcessCook'tan bağımsız, DB/envanter yan etkisi YOK)
-- doğrudan test etmek isteyen geliştiriciler için salt-okunur debug komutu.
RegisterCommand('farmakolojitest', function(src, args)
    local rawWeight  = tonumber(args[1]) or 100.0
    local rawPurity  = tonumber(args[2]) or 0.80
    local agentWeight= tonumber(args[3]) or 100.0
    local skill      = tonumber(args[4]) or 1.0
    local fatigue    = tonumber(args[5]) or 0.0
    local cortisol   = tonumber(args[6]) or 0.0

    local r = Matrix.Kitchen.ComputePharmacologicalDilution(
        rawWeight, rawPurity, agentWeight, skill, fatigue, cortisol)

    Reply(src, ('[PHARMACOLOGICAL_DILUTION_CORE] M_pure=%.4f V_total=%.4f C2_ideal=%.6f err=%.4f out=%.6f waste=%.3fg doyum=%s'):format(
        r.M_pure, r.V_total, r.theoretical_purity, r.error_coefficient,
        r.output_purity, r.waste_volume, tostring(r.molecular_saturation)))
end, false)


exports('FlushKatmanKnowledge', function(botId) return Matrix.Kitchen.FlushKatmanKnowledge(botId) end)
exports('GetKnowledgeMask', function(botId) return Matrix.Kitchen.GetKnowledgeMask(botId) end)

-- ★ [MATRIX:PHARMACOLOGICAL_DILUTION_CORE] Dış modüller (diagnostics/hud)
-- farmakolojik seyreltme çekirdeğini saf olarak çağırabilsin diye export.
exports('ComputePharmacologicalDilution', function(rawWeight, rawPurity, agentWeight, skill, fatigue, cortisol)
    return Matrix.Kitchen.ComputePharmacologicalDilution(rawWeight, rawPurity, agentWeight, skill, fatigue, cortisol)
end)