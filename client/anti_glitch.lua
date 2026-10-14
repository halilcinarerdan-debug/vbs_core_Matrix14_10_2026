-- =====================================================================
-- MATRIX ANTI-GLITCH PVP + GHOST-PEEK + SUPPRESSION / client/anti_glitch.lua
-- (TASK EKI — MODUL 5 / 6 / 7)
--
-- YENİ BİR DOSYA: client/hud.lua zaten 900 satıra yakın, tamamen ayrı bir
-- ilgi alanı (PvP hareket/kamera bütünlüğü) için ayrı dosya tercih edildi
-- (görev talimatı: "or a new client file if hud.lua's structure doesn't
-- fit"). Sunucuya kortizol/bastırma bildirimi client/hud.lua'nın
-- reportPlayerWounded desenini TAKLİT eder -- yeni bir ikinci desen İCAT
-- EDİLMEZ.
--
-- ★ MODUL 5: Strafe-yön-tersine-çevirme (sprint/havadayken) tespiti ->
--   kısa süreli SetPedMoveRateOverride cezası. Birinci şahısta hızlı
--   ardışık zıplama girdisi -> ~1500ms hareket kilidi. Muharebe sırasında
--   "roll/dalış" girdisi (duck+sprint kombosu) -> kontrol TAMAMEN
--   devre dışı + TaskCrouch zorlanır.
-- ★ MODUL 6: "Hayalet bakış" (ghost-peek) -- IsPedShooting true iken
--   kamera rotasyonu ile ped'in gerçek yönelimi (forward vector) arasındaki
--   açı farkı bir eşiği aşarsa (3.şahıs kamera avantajıyla siperin
--   ARKASINDAN, gövde hizalanmadan ateş etme) DisablePlayerFiring çağrılır.
-- ★ MODUL 7: Yakın-ıskalama (~2.5m gövde) bastırma birikimi -> DrawRect
--   tabanlı vinyet/monokrom kararma + server'a kortizol artışı bildirimi.
--   NOT: İstemci tarafında per-mermi "yakın ıskalama" tespiti için GTA V
--   yerlisi (native) YOKTUR -- bu modül, yakınlıktaki düşman ped'lerin
--   AKTİF ATEŞ ETTİĞİ VE ateş hattının oyuncuya hizalı olduğu anları
--   (MODUL 6 ile AYNI açı-farkı yöntemi) bir "baskı altında" vekili olarak
--   kullanır (deterministik, RNG yok) -- gerçek mermi-geçiş simülasyonu
--   değildir; bu, mevcut FiveM API yüzeyiyle en gerçekçi yaklaşımdır.
-- =====================================================================

local PlayerPedId          = PlayerPedId
local GetEntityCoords      = GetEntityCoords
local GetEntityForwardVector = GetEntityForwardVector
local GetGameplayCamRot    = GetGameplayCamRot
local IsPedShooting        = IsPedShooting
local DisablePlayerFiring  = DisablePlayerFiring
local GetGameTimer         = GetGameTimer

-- =====================================================================
-- MODUL 5: STRAFE-TERSİNE-ÇEVİRME + HIZLI-ZIPLAMA + ROLL/DALIŞ
-- =====================================================================
local MOVE_RATE_PENALTY          = 0.7
local MOVE_RATE_PENALTY_MS       = 200
local STRAFE_REVERSAL_WINDOW_MS  = 150
local JUMP_LOCK_MS               = 1500
local JUMP_SPAM_WINDOW_MS        = 900
local JUMP_SPAM_COUNT_THRESHOLD  = 3

local lastLateralSign   = 0
local _penaltyWasActive = false
local lastLateralAt     = 0
local moveRatePenaltyUntil = 0

local jumpTimestamps    = {}
local movementLockUntil = 0

CreateThread(function()
    while true do
        -- ★ [M-15 FIX] Wait(0) → Wait(2) (resmon koruması, 30 FPS yeterli)
        Wait(2)
        local ped = PlayerPedId()
        local now = GetGameTimer()

        -- --- Strafe-yön-tersine-çevirme (sprint/havada) ---
        -- ★ [FIX] 'IsPedOnGround' GTA V/FiveM'de GERCEK BIR NATIVE DEGIL --
        -- global olarak TANIMSIZ, cagrildiginda 'attempt to call a nil
        -- value' hatasiyla BU THREAD coker (diger thread'ler/HUD/F10
        -- ETKILENMEZ, ama bu strafe-tespiti tamamen devre disi kalirdi).
        -- Dogrulanmis RAGE native'i IsEntityInAir ile degistirildi.
        local sprinting = IsPedSprinting(ped)
        local airborne  = IsPedFalling(ped) or IsPedJumping(ped) or IsEntityInAir(ped)

        if sprinting or airborne then
            local lateral = GetControlNormal(0, 30) -- INPUT_MOVE_LR
            local sign = (lateral > 0.35 and 1) or (lateral < -0.35 and -1) or 0

            if sign ~= 0 then
                if lastLateralSign ~= 0 and sign ~= lastLateralSign
                    and (now - lastLateralAt) <= STRAFE_REVERSAL_WINDOW_MS then
                    moveRatePenaltyUntil = now + MOVE_RATE_PENALTY_MS
                end
                lastLateralSign = sign
                lastLateralAt   = now
            end
        else
            lastLateralSign = 0
        end

        if now < moveRatePenaltyUntil then
    SetPedMoveRateOverride(ped, MOVE_RATE_PENALTY)
    _penaltyWasActive = true
elseif _penaltyWasActive and now >= movementLockUntil then
    -- ★ Ceza bitti — motor normale dön
    SetPedMoveRateOverride(ped, 1.0)
    _penaltyWasActive = false
end




        -- --- Birinci şahısta hızlı ardışık zıplama -> hareket kilidi ---
        local firstPerson = GetFollowPedCamViewMode() == 4
        if firstPerson and IsControlJustPressed(0, 22) then -- INPUT_JUMP
            jumpTimestamps[#jumpTimestamps + 1] = now
            local pruned = {}
            for _, t in ipairs(jumpTimestamps) do
                if (now - t) <= JUMP_SPAM_WINDOW_MS then pruned[#pruned + 1] = t end
            end
            jumpTimestamps = pruned
            if #jumpTimestamps >= JUMP_SPAM_COUNT_THRESHOLD then
                movementLockUntil = now + JUMP_LOCK_MS
                jumpTimestamps = {}
            end
        end

        if now < movementLockUntil then
    DisableControlAction(0, 22, true)
    DisableControlAction(0, 24, true)
    SetPedMoveRateOverride(ped, MOVE_RATE_PENALTY)
    _penaltyWasActive = true
elseif _penaltyWasActive and now >= moveRatePenaltyUntil then
    SetPedMoveRateOverride(ped, 1.0)
    _penaltyWasActive = false
end

        -- --- Muharebede roll/dalış (duck+sprint) girdisi -> tamamen kapat + crouch ---
        if IsPedInCombat(ped, 0) then
            local duckPressed = IsControlPressed(0, 36) -- INPUT_DUCK
            if duckPressed and sprinting then
                DisableControlAction(0, 36, true)
                pcall(TaskCrouch, ped, -1)
            end
        end
    end
end)

-- =====================================================================
-- ORTAK: KAMERA/GÖVDE HİZALAMA AÇI FARKI (MODUL 6 + 7'de yeniden kullanılır)
-- =====================================================================
local function AngleDiffDegrees(camRot, forward)
    -- Kamera rotasyonunu (pitch atılmış, sadece yaw) yön vektörüne çevir.
    local yawRad = math.rad(camRot.z)
    local camFwd = vector3(-math.sin(yawRad), math.cos(yawRad), 0.0)

    local a = vector3(camFwd.x, camFwd.y, 0.0)
    local b = vector3(forward.x, forward.y, 0.0)
    local lenA = #a
    local lenB = #b
    if lenA < 0.0001 or lenB < 0.0001 then return 0.0 end

    local dot = (a.x * b.x + a.y * b.y) / (lenA * lenB)
    dot = math.max(-1.0, math.min(1.0, dot))
    return math.deg(math.acos(dot))
end

-- ★ İki vektör arasındaki açı (GTA heading dönüşümü olmadan, direkt)
local function VectorAngleDiff(v1, v2)
    local a = vector3(v1.x, v1.y, 0.0)
    local b = vector3(v2.x, v2.y, 0.0)
    local lenA = #a
    local lenB = #b
    if lenA < 0.0001 or lenB < 0.0001 then return 0.0 end
    local dot = (a.x * b.x + a.y * b.y) / (lenA * lenB)
    dot = math.max(-1.0, math.min(1.0, dot))
    return math.deg(math.acos(dot))
end

-- =====================================================================
-- MODUL 6: HAYALET BAKIŞ (GHOST-PEEK) TESPİTİ
-- =====================================================================
local GHOST_PEEK_ANGLE_THRESHOLD_DEG = 35.0

CreateThread(function()
    while true do
        -- ★ [M-15 FIX] Wait(0) → Wait(2)
        Wait(2)
        local ped = PlayerPedId()
        if IsPedShooting(ped) then            local camRot  = GetGameplayCamRot(2)
            local forward = GetEntityForwardVector(ped)
            local diff = AngleDiffDegrees(camRot, forward)

            if diff > GHOST_PEEK_ANGLE_THRESHOLD_DEG then
                -- Govde ates hattina hizali degil (siper arkasindan 3.sahis
                -- kamera avantajiyla "gorup vurma") -- atisi engelle.
                DisablePlayerFiring(PlayerId(), true)
            end
        end
    end
end)

-- =====================================================================
-- MODUL 7: BASKI / TAKTİK TÜNEL GÖRÜŞÜ
-- =====================================================================
local SUPPRESSION_RADIUS_METERS   = 25.0
local SUPPRESSION_GAIN_PER_TICK   = 0.28
local SUPPRESSION_DECAY_PER_TICK  = 0.15
-- ★ [M-14 FIX] Tick 200→500ms (resmon koruması).
local SUPPRESSION_TICK_MS         = 500
local SUPPRESSION_REPORT_MS       = 1000

-- ★ [M-14 FIX] Ped listesi cache — her tick FindFirstPed taraması YERINE
-- bu kadar tick'te bir yenile (4 × 500ms = 2sn).
local SUPPRESSION_PED_CACHE_TICKS = 4
local _suppressionPedCache        = {}
local _suppressionCacheCounter    = 0
local _suppressionCacheDirty      = true

local suppressionLevel = 0.0 -- 0..1

CreateThread(function()
    local lastReportAt = 0
    while true do
        Wait(SUPPRESSION_TICK_MS)

        local ped = PlayerPedId()
        local playerCoords = GetEntityCoords(ped)

        -- ★ [M-14 FIX] Ped listesi cache — sadece N tick'te bir yenile.
        _suppressionCacheCounter = _suppressionCacheCounter + 1
        if _suppressionCacheCounter >= SUPPRESSION_PED_CACHE_TICKS then
            _suppressionCacheCounter = 0
            _suppressionCacheDirty = true
        end

        if _suppressionCacheDirty then
            _suppressionPedCache = {}
            local handle, otherPed = FindFirstPed()
            local found = true
             repeat
                if otherPed ~= ped
                   and DoesEntityExist(otherPed)
                   and not IsPedAPlayer(otherPed)
                   and not IsPedDeadOrDying(otherPed, true) then
                    _suppressionPedCache[#_suppressionPedCache + 1] = otherPed
                end
                found, otherPed = FindNextPed(handle)
            until not found
            EndFindPed(handle)
            _suppressionCacheDirty = false
        end

          -- ★ Cache'i kullan (FindFirstPed taraması YOK)
        local underFire = false
                for i = 1, #_suppressionPedCache do
            local otherPed = _suppressionPedCache[i]
            if DoesEntityExist(otherPed)
               and not IsPedAPlayer(otherPed)
               and not IsPedDeadOrDying(otherPed, true) then
                local pedCoords = GetEntityCoords(otherPed)
                local d = #(pedCoords - playerCoords)
                local toPlayer = playerCoords - pedCoords
                local diff = VectorAngleDiff(GetEntityForwardVector(otherPed), toPlayer)
                                               -- ★ [SORUN 2 FIX v2] Sokak ped'leri/siviller ateş etmiyorsa
                -- suppression TETİKLEMESİN. Silah kontrolü GetSelectedPedWeapon
                -- ile yapılır (IsPedArmed flag'ları tüfek/SMG'yi kaçırıyordu).
                  -- ★ [ACİL FIX] Sivil ped'ler artık suppression tetiklemiyor.
                -- Önceki filtre "elinde silah var mı" diye bakıyordu →
                -- sivil NPC'ler bazen yanlış silah değeri taşıyor, tetikliyordu.
                -- YENİ: SADECE aşağıdakilerden BİRİ doğruysa tehdit say:
                --   1) Ped ATEŞ EDİYOR (IsPedShooting), VEYA
                --   2) Oyuncuyla SAVAŞ halinde (IsPedInCombat) VE elinde
                --      gerçekten silah VAR (GetSelectedPedWeapon != UNARMED)
                local currentWeapon = GetSelectedPedWeapon(otherPed)
                local hasRealWeapon = currentWeapon ~= 0
                    and currentWeapon ~= `WEAPON_UNARMED`
                    and currentWeapon ~= `WEAPON_UNARMED_2`
                    and currentWeapon ~= `WEAPON_STUNGUN`   -- sivil polis değil

                local isActivelyThreatening = IsPedShooting(otherPed)
                    or (IsPedInCombat(otherPed, ped) and hasRealWeapon)

                if isActivelyThreatening
                   and diff < 90.0
                   and d <= SUPPRESSION_RADIUS_METERS then
                    underFire = true
                    break
                end
            end
        end



                        if underFire then
            suppressionLevel = math.min(1.0, suppressionLevel + SUPPRESSION_GAIN_PER_TICK)
        else
            suppressionLevel = math.max(0.0, suppressionLevel - SUPPRESSION_DECAY_PER_TICK)
        end

        -- ★ [DEBUG] Sadece ANLAMLI değişimde bas (spam yok)
        local lastLoggedLevel = _G.__lastSuppressionLogged or -1.0
        if math.abs(suppressionLevel - lastLoggedLevel) >= 0.10 or
           (suppressionLevel <= 0.05 and lastLoggedLevel > 0.05) then
            _G.__lastSuppressionLogged = suppressionLevel
            print(('[SUPPRESSION] level=%.3f underFire=%s'):format(
                suppressionLevel, tostring(underFire)))
        end

        local now = GetGameTimer()
        if suppressionLevel > 0.0 and (now - lastReportAt) >= SUPPRESSION_REPORT_MS then
            lastReportAt = now
            TriggerServerEvent('matrix:server:reportSuppression', suppressionLevel)
        end
    end
end)

-- =====================================================================
-- ★ VIGNETTE — GTA yerleşik "NG_filmic20" timecycle modifier
-- DrawRect kare çiziyordu (creeper görünümü). Bu sürüm GTA'nın kendi
-- radial vignette efektini kullanır → göz şeklinde yumuşak oval kararma.
-- =====================================================================
local _vignetteActive = false

CreateThread(function()
    while true do
        if suppressionLevel > 0.05 then
            if not _vignetteActive then
                SetTimecycleModifier('NG_filmic20')
                _vignetteActive = true
            end
            -- 0.0 = etkisiz, 1.0 = maksimum kararma
            SetTimecycleModifierStrength(suppressionLevel)
            Wait(50)
        else
            if _vignetteActive then
                ClearTimecycleModifier()
                _vignetteActive = false
            end
            Wait(250)
        end
    end
end)
-- =====================================================================
-- MODUL 7 (devam): KORTİZOL -> NİŞAN SALLANTISI (AIM SWAY)
-- server/wound_system.lua Matrix.Wounds.ApplySuppressionCortisol her
-- bastırma güncellemesinde bu event'i tetikler (mevcut cortisol_level
-- hiçbir yeni ikinci "biyoloji senkronu" İCAT EDİLMEDEN client'a iletilir).
-- Sunucudan gelmeyen aralıklarda değer, doğal toparlanmayla AYNI ruhta
-- yerel olarak yavaşça sıfıra sönümlenir (server tarafı zaten kendi
-- toparlanma formülünü ayrıca uyguluyor -- bu sadece GÖRSEL/HİSSİYAT
-- senkronu, ekonomi/DB durumu değil).
-- =====================================================================
local lastKnownCortisol = 0.0

RegisterNetEvent('matrix:client:cortisolSync', function(cortisolLevel)
    cortisolLevel = tonumber(cortisolLevel)
    if cortisolLevel then
        lastKnownCortisol = math.max(0.0, math.min(1.0, cortisolLevel))
    end
end)

CreateThread(function()
    while true do
        -- ★ [M-15 FIX] Wait(0) → Wait(2)
        Wait(2)
        if lastKnownCortisol > 0.02 then
            local ped = PlayerPedId()
            if IsPedShooting(ped) or IsPlayerFreeAiming(PlayerId()) then
                ShakeGameplayCam('HAND_SHAKE', lastKnownCortisol)
            end
            -- Yerel görsel sönümleme
            lastKnownCortisol = math.max(0.0, lastKnownCortisol - 0.0003)
            Wait(2)
        else
            Wait(200)
        end
    end
end)

AddEventHandler('onResourceStop', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end
    SetPedMoveRateOverride(PlayerPedId(), 1.0)
    -- ★ [SORUN 3 FIX] Kalıntı shake state'i temizle
    StopGameplayCamShaking(true)
end)
-- =====================================================================
-- ★ LAMBS: HASAR ALINCA ANI SUPPRESSION SIÇRAMASI
-- =====================================================================
-- ★ [SORUN 3 FIX] Resource ilk açıldığında önceki oturumdan kalan
-- ShakeGameplayCam state'ini KESİN temizle.
AddEventHandler('onClientResourceStart', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end
    CreateThread(function()
        Wait(500)
        StopGameplayCamShaking(true)
        SetTimecycleModifierStrength(0.0)
        ClearTimecycleModifier()
        print('[ANTI_GLITCH] Residual shake + vignette state temizlendi.')
    end)
end)

local DAMAGE_SPIKE_PER_HIT    = 0.35
local DAMAGE_SPIKE_DECAY_MS   = 3000

AddEventHandler('gameEventTriggered', function(eventName, args)
    if eventName ~= 'CEventNetworkEntityDamage' then return end
    local victim, attacker, weaponDamage = args[1], args[2], args[3]
    if victim ~= PlayerPedId() then return end
    if not weaponDamage then return end

    -- ★ Baskı sıçraması (vignette için)
    suppressionLevel = math.min(1.0, (suppressionLevel or 0.0) + DAMAGE_SPIKE_PER_HIT)

    -- ★ [SORUN 3 FIX] Vurulunca 1 KEZ sarsıntı (sürekli değil)
    ShakeGameplayCam('SMALL_EXPLOSION_SHAKE', DAMAGE_SPIKE_PER_HIT * 0.5)
end)

-- =====================================================================
-- ★ LAMBS: BASTIRMA SIRASINDA EKRAN SALLANMASI
-- suppressionLevel > 0.15 olduğunda ekran hafifçe sarsılır
-- Şiddet suppression seviyesiyle doğru orantılı
-- =====================================================================
-- ★ [SORUN 3 FIX] SÜREKLİ EKRAN SALLAMASI KALDIRILDI.
-- Sarsıntı artık YALNIZCA hasar alındığında (DAMAGE_SPIKE) 1 KEZ tetiklenir.
-- Sürekli suppression altında ekranı sallamak gıcık ediciydi (aralıksız
-- titreme hissi) ve hedeflenen "gerçekçi baskı" hissini vermiyordu.
-- Yerine: DRAW ağırlıklı VIGNETTE kararması bırakıldı (SORUN 2 zaten
-- çalışıyor) — oyuncu ne kadar baskı altındaysa ekran o kadar kararır.
-- Tek seferlik sarsıntı DAMAGE_SPIKE bloğunda kalıyor (aşağıda).