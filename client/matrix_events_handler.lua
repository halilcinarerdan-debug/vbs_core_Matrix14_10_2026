-- =====================================================================
-- MATRIX CLIENT EVENT GATEWAY / client/matrix_events_handler.lua
--
-- Centralized client-side net-event gateway for every matrix:client:*
-- event fired by the server modules but that had no client handler.
--
-- Every payload shape below is VERIFIED against the real
-- TriggerClientEvent / BroadcastToBucket call sites (server/main.lua,
-- server/bureau.lua, server/market.lua, server/recruitment.lua,
-- server/logistics.lua, server/workbench.lua, server/cognition_core.lua)
-- and the real inbound server events it must call back into
-- (server/recruitment.lua's coercionDataReady/coercionCompleted/
-- coercionAborted, server/market.lua's cyberOpInterrupted,
-- server/logistics.lua's arsonDialogResponse/arsonInterrupted). Nothing
-- in this file is a guess.
--
-- Conventions carried over from the server modules in this resource:
--   - every handler body runs through pcall (_SafeHandler) so one bad
--     payload can't kill the resource's event loop.
--   - zero math.random; nothing here is randomized.
--   - proximity/monitor loops tick at 250ms, not per-frame.
-- =====================================================================

local pairs, ipairs, type, tostring, tonumber = pairs, ipairs, type, tostring, tonumber
local CreateThread        = CreateThread
local RegisterNetEvent    = RegisterNetEvent
local TriggerServerEvent  = TriggerServerEvent

Matrix = Matrix or {}
Matrix.EventsHandler = Matrix.EventsHandler or {}

-- =====================================================================
-- UTIL
-- =====================================================================
local function _Log(fmt, ...)
    local n = select('#', ...)
    local line = (n == 0) and fmt or fmt:format(...)
    if type(Matrix.Log) == 'function' then
        local ok = pcall(Matrix.Log, 'EVENTS_HANDLER', line)
        if ok then return end
    end
    print(('[MATRIX:EVENTS_HANDLER] %s'):format(line))
end

local function _SafeHandler(name, fn)
    RegisterNetEvent(name, function(...)
        local ok, err = pcall(fn, ...)
        if not ok then
            _Log('[HATA] %s handler basarisiz (yutuldu): %s', name, tostring(err))
        end
    end)
end

local function _Clamp(v, lo, hi)
    v = tonumber(v)
    if not v or v ~= v then return lo end
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

local function _ResolveNetEntity(netId)
    if type(netId) ~= 'number' or netId <= 0 then return nil end
    local entity = NetworkGetEntityFromNetworkId(netId)
    if not entity or entity == 0 or not DoesEntityExist(entity) then return nil end
    return entity
end

local function _ResolveVehicleByPlate(plate)
    if type(plate) ~= 'string' or plate == '' then return nil end
    local target = plate:gsub('%s+$', ''):upper()
    for _, vehicle in ipairs(GetGamePool('CVehicle')) do
        if DoesEntityExist(vehicle) then
            local vp = GetVehicleNumberPlateText(vehicle)
            if type(vp) == 'string' and vp:gsub('%s+$', ''):upper() == target then
                return vehicle
            end
        end
    end
    return nil
end

local function _LoadModel(model)
    local hash = (type(model) == 'string') and joaat(model) or model
    if type(hash) ~= 'number' or not IsModelValid(hash) then return nil end
    RequestModel(hash)
    local waited = 0
    while not HasModelLoaded(hash) and waited < 5000 do
        Wait(50)
        waited = waited + 50
    end
    if not HasModelLoaded(hash) then return nil end
    return hash
end

--- Runs an ox_lib progressCircle while a background thread polls
--- distance from `anchorCoordsFn()`; cancels the bar the moment the
--- player strays past `radius`. Returns (completed, abortedByProximity).
local function _RunProximityGuardedProgress(progressOpts, anchorCoordsFn, radius)
    if not lib or not lib.progressCircle then
        _Log('progressCircle: ox_lib bulunamadi -- surec atlandi.')
        return false, false
    end

    local monitoring = true
    local abortedByProximity = false

    CreateThread(function()
        while monitoring do
            local anchor = anchorCoordsFn()
            if not anchor then
                abortedByProximity = true
                if lib.cancelProgress then lib.cancelProgress() end
                break
            end
            local dist = #(GetEntityCoords(PlayerPedId()) - anchor)
            if dist > radius then
                abortedByProximity = true
                if lib.cancelProgress then lib.cancelProgress() end
                break
            end
            Wait(250)
        end
    end)

    local completed = lib.progressCircle(progressOpts)
    monitoring = false
    return completed, abortedByProximity
end

-- =====================================================================
-- [1] BOT YAŞAM DÖNGÜSÜ — matrix:client:injectBot / matrix:client:extractBot
-- server/main.lua: TriggerClientEvent('matrix:client:injectBot', -1, id,
--   bot.role, coords, bot.dna_id, netId)
-- server/main.lua: TriggerClientEvent('matrix:client:extractBot', -1, id)
-- =====================================================================
local InjectedBotBlips = {}

local function _OnInjectBot(botId, role, coords, dnaId, netId)
    botId = tonumber(botId)
    if not botId then return end

    local entity = _ResolveNetEntity(netId)
    if not entity then
        _Log('injectBot: netId=%s entity cozulemedi (henuz senkronize olmamis olabilir).', tostring(netId))
        return
    end

    if InjectedBotBlips[botId] and DoesBlipExist(InjectedBotBlips[botId]) then
        RemoveBlip(InjectedBotBlips[botId])
        InjectedBotBlips[botId] = nil
    end

    local blip = AddBlipForEntity(entity)
    SetBlipSprite(blip, 1)
    SetBlipColour(blip, 5)
    SetBlipScale(blip, 0.75)
    SetBlipAsShortRange(blip, true)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentSubstringPlayerName(('AJAN #%d (%s)'):format(botId, tostring(role or '?')))
    EndTextCommandSetBlipName(blip)
    InjectedBotBlips[botId] = blip

    _Log('injectBot: bot #%d (%s, dna=%s) enjekte edildi netId=%s.', botId, tostring(role), tostring(dnaId), tostring(netId))
end
_SafeHandler('matrix:client:injectBot', _OnInjectBot)

local function _OnExtractBot(botId)
    botId = tonumber(botId)
    if not botId then return end

    local blip = InjectedBotBlips[botId]
    if blip and DoesBlipExist(blip) then
        RemoveBlip(blip)
    end
    InjectedBotBlips[botId] = nil

    _Log('extractBot: bot #%d sahadan cekildi.', botId)
end
_SafeHandler('matrix:client:extractBot', _OnExtractBot)

-- =====================================================================
-- [2] BASKIN YÜRÜTME — matrix:client:executeRaid
-- server/bureau.lua: TriggerClientEvent('matrix:client:executeRaid', -1,
--   trapHouseId, house.coords, { squad_size, breach_method, escape_window })
-- Broadcast (-1); yalnizca trap house'a yakin oyuncu fiziksel efekt alir.
-- =====================================================================
local RAID_NEARBY_RADIUS = 60.0

local function _OnExecuteRaid(trapHouseId, coords, raidInfo)
    trapHouseId = tonumber(trapHouseId)
    if not trapHouseId then return end
    if type(coords) ~= 'table' and type(coords) ~= 'vector3' and type(coords) ~= 'vector4' then return end
    raidInfo = type(raidInfo) == 'table' and raidInfo or {}

    local squadSize    = tonumber(raidInfo.squad_size) or 0
    local breachMethod = tostring(raidInfo.breach_method or 'ram')
    local escapeWindow = tonumber(raidInfo.escape_window) or 0

    local dist = #(GetEntityCoords(PlayerPedId()) - vector3(coords.x, coords.y, coords.z))

    if dist <= RAID_NEARBY_RADIUS then
        if lib and lib.notify then
            lib.notify({
                title       = 'ŞAFAK BASKINI',
                description = ('%d birim, giriş:%s, kaçış penceresi:%ds'):format(squadSize, breachMethod, escapeWindow),
                type        = 'error',
                duration    = 8000
            })
        end
        PlaySoundFrontend(-1, 'Lose_1st', 'GTAO_FM_Events_Soundset', true)
    end

    _Log('executeRaid: trap #%d squad=%d breach=%s escape=%ds mesafe=%.1fm',
        trapHouseId, squadSize, breachMethod, escapeWindow, dist)
end
_SafeHandler('matrix:client:executeRaid', _OnExecuteRaid)

-- =====================================================================
-- [3] TELSİZ STATİK PARAZİTİ — matrix:client:applyRadioStatic
-- server/main.lua: TriggerClientEvent('matrix:client:applyRadioStatic',
--   targetSrc, intensity, reason or 'unknown')
-- =====================================================================
Matrix.EventsHandler.RadioStaticIntensity = 0.0

local function _OnApplyRadioStatic(intensity, reason)
    intensity = _Clamp(intensity, 0.0, 1.0)
    Matrix.EventsHandler.RadioStaticIntensity = intensity

    if intensity > 0.05 then
        PlaySoundFrontend(-1, 'GENERIC_CHAT_MESSAGE', 'HUD_FRONTEND_DEFAULT_SOUNDSET', false)
    end

    _Log('applyRadioStatic: intensity=%.3f reason=%s', intensity, tostring(reason or '?'))
end
_SafeHandler('matrix:client:applyRadioStatic', _OnApplyRadioStatic)

exports('GetRadioStaticIntensity', function() return Matrix.EventsHandler.RadioStaticIntensity end)

-- =====================================================================
-- [4] COERCION DİZİSİ — matrix:client:freezeEntity / gatherCoercionData /
-- beginCoercionProgress
-- server/recruitment.lua:
--   TriggerClientEvent('matrix:client:freezeEntity', -1, c.target_net_id, cfg.FreezeDurationMs)
--   TriggerClientEvent('matrix:client:gatherCoercionData', src, targetNetId)
--   TriggerClientEvent('matrix:client:beginCoercionProgress', clientSource, {
--       coercion_id, target_net_id, duration_ms, abort_distance, title })
-- Geri-çağrılar: matrix:server:coercionDataReady(targetNetId, targetData),
-- matrix:server:coercionCompleted(coercionId),
-- matrix:server:coercionAborted(coercionId, reason).
-- =====================================================================
local function _OnFreezeEntity(netId, durationMs)
    local entity = _ResolveNetEntity(netId)
    if not entity then
        _Log('freezeEntity: netId=%s cozulemedi.', tostring(netId))
        return
    end
    durationMs = tonumber(durationMs)
    if not durationMs or durationMs < 0 then durationMs = 0 end

    FreezeEntityPosition(entity, true)
    _Log('freezeEntity: entity netId=%s donduruldu (sure=%dms).', tostring(netId), durationMs)

    if durationMs > 0 then
        CreateThread(function()
            Wait(durationMs)
            if DoesEntityExist(entity) then
                FreezeEntityPosition(entity, false)
                _Log('freezeEntity: entity netId=%s cozuldu (sure doldu).', tostring(netId))
            end
        end)
    end
end
_SafeHandler('matrix:client:freezeEntity', _OnFreezeEntity)

local function _OnGatherCoercionData(targetNetId)
    local entity = _ResolveNetEntity(targetNetId)
    local coords = entity and GetEntityCoords(entity) or nil

    local targetData = {
        net_id = targetNetId,
        coords = coords and { x = coords.x, y = coords.y, z = coords.z } or nil,
    }

    TriggerServerEvent('matrix:server:coercionDataReady', targetNetId, targetData)

    if lib and lib.notify then
        lib.notify({
            title       = 'İSTİHBARAT TOPLANIYOR',
            description = 'Hedef üzerinde zorlama dosyası derleniyor...',
            type        = 'inform'
        })
    end

    _Log('gatherCoercionData: hedef netId=%s icin veri sunucuya bildirildi.', tostring(targetNetId))
end
_SafeHandler('matrix:client:gatherCoercionData', _OnGatherCoercionData)

local function _OnBeginCoercionProgress(payload)
    if type(payload) ~= 'table' then return end

    local coercionId    = payload.coercion_id
    local targetNetId   = payload.target_net_id
    local durationMs    = tonumber(payload.duration_ms) or 15000
    local abortDistance = tonumber(payload.abort_distance) or 3.0
    local title          = (type(payload.title) == 'string' and payload.title ~= '')
        and payload.title or 'AJAN PSIKOLOJIK COERCION SURECI...'

    local anchor = _ResolveNetEntity(targetNetId)
    if not anchor then
        _Log('beginCoercionProgress: hedef netId=%s cozulemedi -- iptal.', tostring(targetNetId))
        return
    end

    local completed, abortedByProximity = _RunProximityGuardedProgress({
        duration     = durationMs,
        label        = title,
        position     = 'bottom',
        useWhileDead = false,
        canCancel    = true,
        disable      = { move = true, car = true, combat = true, mouse = false },
        anim         = { dict = 'mp_arresting', clip = 'a_uncuff' },
    }, function()
        return DoesEntityExist(anchor) and GetEntityCoords(anchor) or nil
    end, abortDistance)

    if abortedByProximity or not completed then
        TriggerServerEvent('matrix:server:coercionAborted', coercionId,
            abortedByProximity and 'proximity_break' or 'cancelled')
        if lib and lib.notify then
            lib.notify({ title = 'COERCION', description = 'Süreç kesintiye uğradı.', type = 'error' })
        end
        _Log('beginCoercionProgress: iptal (coercion_id=%s aborted=%s completed=%s).',
            tostring(coercionId), tostring(abortedByProximity), tostring(completed))
    else
        TriggerServerEvent('matrix:server:coercionCompleted', coercionId)
        _Log('beginCoercionProgress: tamamlandi (coercion_id=%s).', tostring(coercionId))
    end
end
_SafeHandler('matrix:client:beginCoercionProgress', _OnBeginCoercionProgress)

-- =====================================================================
-- [5] SİBER OPERASYON — matrix:client:cyberOpStart / cyberOpAborted /
-- cyberOpCompleted
-- server/market.lua:
--   TriggerClientEvent('matrix:client:cyberOpStart', src,
--       'cyber_erase', durationMs, Matrix.CyberOps.Config.MaxActorRadiusM)
--   TriggerClientEvent('matrix:client:cyberOpAborted', src, reason)
--   TriggerClientEvent('matrix:client:cyberOpCompleted', src, session.op_type)
-- Sunucu KENDI end_ts tick'iyle otomatik tamamlar -- client tamamlanma
-- bildirmez, yalnizca kesinti (matrix:server:cyberOpInterrupted) bildirir.
-- =====================================================================
Matrix.EventsHandler.CyberOpActive = false

local function _OnCyberOpStart(opType, durationMs, maxActorRadiusM)
    durationMs       = tonumber(durationMs) or 100000
    maxActorRadiusM  = tonumber(maxActorRadiusM) or 5.0
    opType           = tostring(opType or 'cyber_op')

    Matrix.EventsHandler.CyberOpActive = true
    local startCoords = GetEntityCoords(PlayerPedId())

    CreateThread(function()
        local completed, abortedByProximity = _RunProximityGuardedProgress({
            duration     = durationMs,
            label        = 'SİBER SIZMA...',
            position     = 'bottom',
            useWhileDead = false,
            canCancel    = true,
            disable      = { move = true, car = true, combat = true },
        }, function() return startCoords end, maxActorRadiusM)

        if not Matrix.EventsHandler.CyberOpActive then return end
        Matrix.EventsHandler.CyberOpActive = false

        if abortedByProximity or not completed then
            TriggerServerEvent('matrix:server:cyberOpInterrupted', opType,
                abortedByProximity and 'proximity_break' or 'cancelled')
        end
        -- Basarili tamamlanma sunucu tarafinda otomatik islenir; client
        -- burada herhangi bir "complete" event'i GONDERMEZ.
    end)

    _Log('cyberOpStart: opType=%s sure=%dms radius=%.1fm', opType, durationMs, maxActorRadiusM)
end
_SafeHandler('matrix:client:cyberOpStart', _OnCyberOpStart)

local function _OnCyberOpAborted(reason)
    Matrix.EventsHandler.CyberOpActive = false
    if lib and lib.cancelProgress then lib.cancelProgress() end
    if lib and lib.notify then
        lib.notify({ title = 'SİBER OPERASYON', description = ('İptal: %s'):format(tostring(reason or '?')), type = 'error' })
    end
    _Log('cyberOpAborted: reason=%s', tostring(reason))
end
_SafeHandler('matrix:client:cyberOpAborted', _OnCyberOpAborted)

local function _OnCyberOpCompleted(opType)
    Matrix.EventsHandler.CyberOpActive = false
    if lib and lib.notify then
        lib.notify({ title = 'SİBER OPERASYON', description = ('Tamamlandı: %s'):format(tostring(opType or '?')), type = 'success' })
    end
    _Log('cyberOpCompleted: opType=%s', tostring(opType))
end
_SafeHandler('matrix:client:cyberOpCompleted', _OnCyberOpCompleted)

-- =====================================================================
-- [6] ADLİ ASİT TEMİZLİĞİ — matrix:client:forensicAcidStart
-- server/market.lua: TriggerClientEvent('matrix:client:forensicAcidStart', src,
--   evidenceId, cfg.DurationMs, cfg.MaxActorRadiusM,
--   cfg.AnimationDict, cfg.AnimationClip, cfg.PropModel)
-- Ayni Matrix.CyberOps.BySrc oturum/otomatik-tamamlama mekanizmasini
-- paylasir (op_type='forensic'); kesinti ayni matrix:server:
-- cyberOpInterrupted event'i uzerinden bildirilir.
-- =====================================================================
local function _OnForensicAcidStart(evidenceId, durationMs, maxActorRadiusM, animDict, animClip, propModel)
    durationMs      = tonumber(durationMs) or 90000
    maxActorRadiusM = tonumber(maxActorRadiusM) or 5.0

    local startCoords = GetEntityCoords(PlayerPedId())
    local prop = nil

    if type(propModel) == 'string' and propModel ~= '' then
        local hash = _LoadModel(propModel)
        if hash then
            prop = CreateObject(hash, startCoords.x, startCoords.y, startCoords.z, true, true, false)
            AttachEntityToEntity(prop, PlayerPedId(), GetPedBoneIndex(PlayerPedId(), 28422),
                0.1, 0.0, 0.0, 0.0, 0.0, 0.0, true, true, false, true, 1, true)
            SetModelAsNoLongerNeeded(hash)
        end
    end

    if type(animDict) == 'string' and animDict ~= '' then
        RequestAnimDict(animDict)
        local waited = 0
        while not HasAnimDictLoaded(animDict) and waited < 3000 do
            Wait(50)
            waited = waited + 50
        end
        if HasAnimDictLoaded(animDict) then
            TaskPlayAnim(PlayerPedId(), animDict, animClip or 'base', 3.0, -3.0, -1, 1, 0, false, false, false)
        end
    end

    local completed, abortedByProximity = _RunProximityGuardedProgress({
        duration     = durationMs,
        label        = 'ADLİ İZLER ASİTLE TEMİZLENİYOR...',
        position     = 'bottom',
        useWhileDead = false,
        canCancel    = true,
        disable      = { move = true, car = true, combat = true },
    }, function() return startCoords end, maxActorRadiusM)

    ClearPedTasks(PlayerPedId())
    if prop and DoesEntityExist(prop) then
        DeleteObject(prop)
    end

    if abortedByProximity or not completed then
        TriggerServerEvent('matrix:server:cyberOpInterrupted', 'forensic',
            abortedByProximity and 'proximity_break' or 'cancelled')
    end

    _Log('forensicAcidStart: evidenceId=%s tamamlandi=%s (sure=%dms)', tostring(evidenceId), tostring(completed), durationMs)
end
_SafeHandler('matrix:client:forensicAcidStart', _OnForensicAcidStart)

-- =====================================================================
-- [7] VETTING DOSYASI — matrix:client:vettingDossier
-- server/main.lua: TriggerClientEvent('matrix:client:vettingDossier', src, {
--   net_id, name, addiction_level, dna_id, forensic_link,
--   low_purity_batches, psychology = { fear_factor, resilience, snitch_tendency } })
-- =====================================================================
local function _OnVettingDossier(dossier)
    if type(dossier) ~= 'table' then return end
    local psych = type(dossier.psychology) == 'table' and dossier.psychology or {}

    local content = ('Ad: %s\nDNA: %s\nBağımlılık: %.1f\nAdli bağlantı: %s\nDüşük saflık satışı: %d\n\nKorku: %.2f | Direnç: %.2f | İhbar eğilimi: %.2f'):format(
        tostring(dossier.name or '?'),
        tostring(dossier.dna_id or '?'),
        tonumber(dossier.addiction_level) or 0.0,
        tostring(dossier.forensic_link and 'VAR' or 'yok'),
        tonumber(dossier.low_purity_batches) or 0,
        tonumber(psych.fear_factor) or 0.0,
        tonumber(psych.resilience) or 0.0,
        tonumber(psych.snitch_tendency) or 0.0
    )

    if lib and lib.alertDialog then
        lib.alertDialog({
            header   = 'VETTING DOSYASI',
            content  = content,
            centered = true,
            cancel   = false
        })
    end
    _Log('vettingDossier: netId=%s icin dosya goruntulendi.', tostring(dossier.net_id))
end
_SafeHandler('matrix:client:vettingDossier', _OnVettingDossier)

-- =====================================================================
-- [8] SAHTE LSPD PUSUYA DÜŞÜRME UYARISI — matrix:client:fakeLspdBulletin
-- server/cognition_core.lua: TriggerClientEvent('matrix:client:fakeLspdBulletin',
--   -1, bot.id, trapId, bot.state and bot.state.coords or nil)
-- Bu bir metin bülteni DEGIL -- bir botun paranoit krizinin urettigi
-- sahte "pusuya dusurme" konum uyarisidir. Broadcast (-1); yalnizca
-- ilgili trap house'a yakin oyuncu HUD uyarisi alir.
-- =====================================================================
local BULLETIN_NEARBY_RADIUS = 80.0

local function _OnFakeLspdBulletin(botId, trapHouseId, coords)
    if type(coords) ~= 'table' and type(coords) ~= 'vector3' and type(coords) ~= 'vector4' then return end

    local dist = #(GetEntityCoords(PlayerPedId()) - vector3(coords.x, coords.y, coords.z))
    if dist > BULLETIN_NEARBY_RADIUS then return end

    if lib and lib.notify then
        lib.notify({
            title       = 'LSPD BÜLTENİ (ŞÜPHELİ)',
            description = ('Bot #%s civarında pusu ihbarı -- kaynağı doğrulanamadı.'):format(tostring(botId)),
            type        = 'error',
            duration    = 6000
        })
    end
    _Log('fakeLspdBulletin: bot #%s trap #%s mesafe=%.1fm.', tostring(botId), tostring(trapHouseId), dist)
end
_SafeHandler('matrix:client:fakeLspdBulletin', _OnFakeLspdBulletin)

-- =====================================================================
-- [9] KUNDAKLAMA DİZİSİ (ARAÇ, PLAKA-BAZLI) — matrix:client:arsonAlertDialog /
-- arsonFrictionStart / arsonIgnite / arsonFireIntensity / arsonResolved
-- server/logistics.lua:
--   TriggerClientEvent('matrix:client:arsonAlertDialog', src, plate, ARSON_DIALOG_WARNING)
--   TriggerClientEvent('matrix:client:arsonFrictionStart', src, plate, Matrix.Arson.Config.ProgressMs)
--   TriggerClientEvent('matrix:client:arsonIgnite', -1, plate)
--   TriggerClientEvent('matrix:client:arsonFireIntensity', -1, session.plate, normalized)
--   TriggerClientEvent('matrix:client:arsonResolved', -1, plate, phase)
-- Geri-çağrılar: matrix:server:arsonDialogResponse(plate, confirmed),
-- matrix:server:arsonInterrupted(plate, reason).
-- =====================================================================
local ARSON_MAX_ACTOR_RADIUS = 3.0 -- Matrix.Arson.Config.MaxActorRadius (server) ile ayni

Matrix.EventsHandler.ArsonFireHandles = {}

local function _OnArsonAlertDialog(plate, warningText)
    if type(plate) ~= 'string' or plate == '' then return end
    if lib and lib.alertDialog then
        local result = lib.alertDialog({
            header   = 'KUNDAKLAMA',
            content  = tostring(warningText or 'Bu aracı yakmak geri alınamaz bir eylemdir.'),
            centered = true,
            cancel   = true
        })
        TriggerServerEvent('matrix:server:arsonDialogResponse', plate, result == 'confirm')
    end
    _Log('arsonAlertDialog: plaka=%s gosterildi.', plate)
end
_SafeHandler('matrix:client:arsonAlertDialog', _OnArsonAlertDialog)

local function _OnArsonFrictionStart(plate, durationMs)
    if type(plate) ~= 'string' or plate == '' then return end
    durationMs = tonumber(durationMs) or 90000

    local vehicle = _ResolveVehicleByPlate(plate)
    if not vehicle then
        _Log('arsonFrictionStart: plaka=%s icin arac bulunamadi -- yerel takip yapilamiyor.', plate)
        return
    end

    local completed, abortedByProximity = _RunProximityGuardedProgress({
        duration     = durationMs,
        label        = 'SÜRTÜNME İLE ATEŞLEME HAZIRLANIYOR...',
        position     = 'bottom',
        useWhileDead = false,
        canCancel    = true,
        disable      = { move = true, car = true, combat = true },
    }, function() return DoesEntityExist(vehicle) and GetEntityCoords(vehicle) or nil end, ARSON_MAX_ACTOR_RADIUS)

    if abortedByProximity or not completed then
        TriggerServerEvent('matrix:server:arsonInterrupted', plate,
            abortedByProximity and 'proximity_break' or 'cancelled')
    end
    -- Basarili tamamlanma sunucu tarafinda kendi zamanlayicisiyla
    -- islenir (ardindan arsonIgnite gelir) -- client "complete" bildirmez.
    _Log('arsonFrictionStart: plaka=%s tamamlandi=%s aborted=%s', plate, tostring(completed), tostring(abortedByProximity))
end
_SafeHandler('matrix:client:arsonFrictionStart', _OnArsonFrictionStart)

local function _OnArsonIgnite(plate)
    if type(plate) ~= 'string' or plate == '' then return end

    local vehicle = _ResolveVehicleByPlate(plate)
    if not vehicle then
        _Log('arsonIgnite: plaka=%s icin arac bulunamadi.', plate)
        return
    end

    if Matrix.EventsHandler.ArsonFireHandles[plate] then
        pcall(RemoveScriptFire, Matrix.EventsHandler.ArsonFireHandles[plate])
        Matrix.EventsHandler.ArsonFireHandles[plate] = nil
    end

    local coords = GetEntityCoords(vehicle)
    local handle = StartScriptFire(coords.x, coords.y, coords.z, 20, false)
    Matrix.EventsHandler.ArsonFireHandles[plate] = handle
    SetVehicleEngineHealth(vehicle, 0.0)

    _Log('arsonIgnite: plaka=%s ates baslatildi (handle=%s).', plate, tostring(handle))
end
_SafeHandler('matrix:client:arsonIgnite', _OnArsonIgnite)

local function _OnArsonFireIntensity(plate, intensity)
    if type(plate) ~= 'string' or plate == '' then return end
    intensity = _Clamp(intensity, 0.0, 1.0)

    if intensity > 0.75 and lib and lib.notify then
        lib.notify({ title = 'KUNDAKLAMA', description = ('%s kontrolden çıkıyor.'):format(plate), type = 'error' })
    end

    _Log('arsonFireIntensity: plaka=%s intensity=%.2f', plate, intensity)
end
_SafeHandler('matrix:client:arsonFireIntensity', _OnArsonFireIntensity)

local function _OnArsonResolved(plate, phase)
    if type(plate) ~= 'string' or plate == '' then return end

    if Matrix.EventsHandler.ArsonFireHandles[plate] then
        pcall(RemoveScriptFire, Matrix.EventsHandler.ArsonFireHandles[plate])
        Matrix.EventsHandler.ArsonFireHandles[plate] = nil
    end

    local label = ({
        sanitized = 'Adli izler tamamen silindi.',
        salvaged  = 'Araç söndürüldü, izler kurtarılabilir kaldı.',
        aborted   = 'Kundaklama iptal edildi.',
    })[tostring(phase)] or ('Sonuç: %s'):format(tostring(phase))

    if lib and lib.notify then
        lib.notify({ title = 'KUNDAKLAMA', description = label, type = 'inform' })
    end
    _Log('arsonResolved: plaka=%s phase=%s', plate, tostring(phase))
end
_SafeHandler('matrix:client:arsonResolved', _OnArsonResolved)

-- =====================================================================
-- [10] WORKBENCH NAMLU PROP'U — matrix:client:workbench:materializeBarrel /
-- workbench:dematerializeBarrel
-- server/workbench.lua (BroadcastToBucket -> TriggerClientEvent):
--   materializeBarrel(trapHouseId, { x, y, z, w })
--   dematerializeBarrel(trapHouseId)
-- Konum sunucu tarafindan zaten hesaplanip gonderiliyor -- client
-- Config'i kendi basina okumuyor.
-- =====================================================================
local WORKBENCH_BARREL_MODEL = 'prop_gun_barrel_01'
local _workbenchBarrelProp = nil

local function _OnMaterializeBarrel(trapHouseId, pos)
    if type(pos) ~= 'table' or not pos.x or not pos.y or not pos.z then
        _Log('workbench:materializeBarrel: gecersiz pos payload (trap #%s).', tostring(trapHouseId))
        return
    end

    if _workbenchBarrelProp and DoesEntityExist(_workbenchBarrelProp) then
        DeleteObject(_workbenchBarrelProp)
        _workbenchBarrelProp = nil
    end

    


    local hash = _LoadModel(WORKBENCH_BARREL_MODEL)
    if not hash then
        _Log('workbench:materializeBarrel: model yuklenemedi (%s).', WORKBENCH_BARREL_MODEL)
        return
    end

    local prop = CreateObject(hash, pos.x, pos.y, pos.z, true, true, false)
    SetEntityHeading(prop, tonumber(pos.w) or 0.0)
    FreezeEntityPosition(prop, true)
    SetModelAsNoLongerNeeded(hash)

    _workbenchBarrelProp = prop
    _Log('workbench:materializeBarrel: trap #%s (%.2f,%.2f,%.2f) uzerinde sabitlendi.',
        tostring(trapHouseId), pos.x, pos.y, pos.z)
end
-- ★ MANDATE: Statik prop_gun_barrel_01 materyalizasyonu kaldırıldı.
-- Oyuncu kendi kit'i ile prop deploy eder.
_SafeHandler('matrix:client:workbench:materializeBarrel', function()
    -- Statik prop materyalizasyonu kaldırıldı (SESSION 4.99 MANDATE).
    -- Oyuncu kendi chemical_workbench_kit/botany_cabinet_kit'ini deploy eder.
end)
local function _OnDematerializeBarrel(trapHouseId)
    if _workbenchBarrelProp and DoesEntityExist(_workbenchBarrelProp) then
        DeleteObject(_workbenchBarrelProp)
        _Log('workbench:dematerializeBarrel: trap #%s prop temizlendi.', tostring(trapHouseId))
    end
    _workbenchBarrelProp = nil
end
_SafeHandler('matrix:client:workbench:dematerializeBarrel', _OnDematerializeBarrel)

-- =====================================================================
-- [11] PAKETLEME ODASI HINT'I (GROUNDED) —
-- matrix:client:workbench:packagingRoomStateChanged
-- server/workbench.lua Matrix.Workbench.TogglePackagingRoom:
--   BroadcastToBucket(trapHouseId, 'matrix:client:workbench:packagingRoomStateChanged', newState)
-- Ayni bucket'taki (trap house icindeki) HERKESE gider.
-- =====================================================================
local function _OnPackagingRoomStateChanged(newState)
    if lib and lib.notify then
        lib.notify({
            title       = '[PAKETLEME ODASI]',
            description = newState and 'Paketleme odası başlatıldı.' or 'Paketleme odası durduruldu.',
            type        = newState and 'success' or 'inform'
        })
    end
    _Log('workbench:packagingRoomStateChanged: yeni durum=%s', tostring(newState))
end
_SafeHandler('matrix:client:workbench:packagingRoomStateChanged', _OnPackagingRoomStateChanged)

-- =====================================================================
-- KAYNAK DURDURMA TEMİZLİĞİ
-- =====================================================================
AddEventHandler('onClientResourceStop', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end

    if _workbenchBarrelProp and DoesEntityExist(_workbenchBarrelProp) then
        DeleteObject(_workbenchBarrelProp)
    end
    for _, handle in pairs(Matrix.EventsHandler.ArsonFireHandles or {}) do
        pcall(RemoveScriptFire, handle)
    end
    for _, blip in pairs(InjectedBotBlips) do
        if DoesBlipExist(blip) then RemoveBlip(blip) end
    end
end)


-- =====================================================================
-- [SESSION 4.99 MANDATE] STATIC WORKBENCH ZONE — KALDIRILDI
-- =====================================================================
-- ★ SINGLE SOURCE OF INTERIOR MARKER mandate'i gereği, eski statik
-- sphere-zone burada DEĞİL, oyuncunun kendisi fiziksel olarak deploy
-- ettiği prop'un ox_target context'i üzerinden yönetilir.
-- (bkz. server/prop_registry.lua + client/prop_placement.lua)
--
-- Bu blok KASITLI OLARAK BOŞTUR. Silmeyin — yeni bir statik marker
-- kazara geri eklenmesin diye burada duruyor.


-- =====================================================================
-- [12] POLICE RAID PED CONFIGURE — [SORUN 1 FIX]
-- server/police_raid.lua'daki SetPedAccuracy/SetPedCombatAttributes gibi
-- native'ler server'da NO-OP idi → polis default GTA AI isabeti (%75-90)
-- kullanıyordu. Bu handler, ped spawn'ı sonrası server'ın gönderdiği
-- configure payload'ını YALNIZCA NetOwner ise uygular (OneSync AI
-- otoritesi NetOwner'da kalır).
-- =====================================================================
local function _OnPoliceRaidConfigurePed(pedNetId, config)
    if type(pedNetId) ~= 'number' or pedNetId <= 0 then return end
    if type(config) ~= 'table' then return end

    local entity = NetworkGetEntityFromNetworkId(pedNetId)
    if not entity or entity == 0 or not DoesEntityExist(entity) then
        return
    end

    -- Sadece NetOwner ped AI'sini gerçekten kontrol eder.
    -- NetOwner değilsek: no-op (broadcast alıcısıyız ama uygulama yetkimiz yok).
    local ok, owner = pcall(NetworkGetEntityOwner, entity)
    if not ok or owner ~= PlayerId() then
        return
    end

    if type(config.accuracy) == 'number' then
        SetPedAccuracy(entity, config.accuracy)
    end

    if config.blocking_events ~= nil then
        SetBlockingOfNonTemporaryEvents(entity, config.blocking_events and true or false)
    end
    if type(config.flee_attributes) == 'number' then
        SetPedFleeAttributes(entity, config.flee_attributes, false)
    end
    if type(config.combat_attributes) == 'number' then
        SetPedCombatAttributes(entity, config.combat_attributes, true)
    end
    if type(config.combat_ability) == 'number' then
        SetPedCombatAbility(entity, config.combat_ability)
    end
    if type(config.combat_range) == 'number' then
        SetPedCombatRange(entity, config.combat_range)
    end

    _Log('policeRaid:configurePed: netId=%d accuracy=%s (NetOwner uyguladı)',
        pedNetId, tostring(config.accuracy))
end
_SafeHandler('matrix:client:policeRaid:configurePed', _OnPoliceRaidConfigurePed)


-- =====================================================================
-- [13] POLICE RAID ENGAGE TARGET — [SORUN 1 FIX v2]
-- TaskCombatPed server'da no-op. NetOwner client'ta çalışır.
-- =====================================================================
local function _OnPoliceRaidEngageTarget(pedNetId, targetNetId)
    if type(pedNetId) ~= 'number' or pedNetId <= 0 then return end
    if type(targetNetId) ~= 'number' or targetNetId <= 0 then return end

    local ped = NetworkGetEntityFromNetworkId(pedNetId)
    if not ped or ped == 0 or not DoesEntityExist(ped) then return end

    local target = NetworkGetEntityFromNetworkId(targetNetId)
    if not target or target == 0 or not DoesEntityExist(target) then return end

    -- Sadece NetOwner ped AI'sini kontrol eder
    local ok, owner = pcall(NetworkGetEntityOwner, ped)
    if not ok or owner ~= PlayerId() then return end

    TaskCombatPed(ped, target, 0, 16)
    _Log('policeRaid:engageTarget: ped=%d target=%d (NetOwner uyguladı)', pedNetId, targetNetId)
end
_SafeHandler('matrix:client:policeRaid:engageTarget', _OnPoliceRaidEngageTarget)


-- =====================================================================
-- [14] POLICE RAID APPROACH — Van'ı hedefe client-side sürer
-- Server SetEntityCoords OneSync'te güvenilmez; TaskVehicleDriveToCoord
-- gerçek AI sürüşüdür, NetOwner client'ta çalışır.
-- =====================================================================
local _lastApproachAt = 0
local function _OnPoliceRaidApproachTarget(vehNetId, x, y, z, speed)
    if type(vehNetId) ~= 'number' or vehNetId <= 0 then return end
    if type(x) ~= 'number' or type(y) ~= 'number' or type(z) ~= 'number' then return end

    local veh = NetworkGetEntityFromNetworkId(vehNetId)
    if not veh or veh == 0 or not DoesEntityExist(veh) then return end

    -- NetOwner kontrolü
    local ok, owner = pcall(NetworkGetEntityOwner, veh)
    if not ok or owner ~= PlayerId() then return end

    local driver = GetPedInVehicleSeat(veh, -1)
    if not driver or driver == 0 or not DoesEntityExist(driver) then return end

    -- Throttle: her 1.5 sn'de bir yeniden task ata (task zaten devam eder)
    local now = GetGameTimer()
    if (now - _lastApproachAt) < 1500 then return end
    _lastApproachAt = now

    TaskVehicleDriveToCoord(
        driver, veh,
        x, y, z,
        speed or 15.0,
        0,
        GetEntityModel(veh),
        16777216,   -- aggressive drive style
        5.0,
        1
    )
    _Log('policeRaid:approachTarget: veh=%d -> (%.1f,%.1f,%.1f) speed=%.1f',
        vehNetId, x, y, z, speed or 15.0)
end
_SafeHandler('matrix:client:policeRaid:approachTarget', _OnPoliceRaidApproachTarget)