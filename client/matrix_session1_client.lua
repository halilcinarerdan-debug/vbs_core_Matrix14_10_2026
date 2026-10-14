-- =====================================================================
-- PROJECT MATRIX — SESSION 1 — RECON WATCHDOG (CLIENT)
--
-- ★ 0.00ms IDLE: yalnızca onClientResourceStart'ta bir seferlik init
--   thread'i. Per-frame loop YOK. Mesafe denetimi ox_target tarafından
--   yerel yürütülür — game loop overhead'i YOK.
--
-- ★ LOCAL SQUARED VECTOR MATH: #(a - b)
-- =====================================================================

-- ★ [SESSION1 KALİBRASYON] Yol ortasından kaldırıma/bina önüne çekildi.
-- Oyun içinde istediğin gibi ince ayar yapılabilsin diye koordinatlar
-- tek noktada toplanmıştır. /coords ile yeni değer alıp buraya yaz.
local BROKER_COORDS    = vector4(143.80, -1025.20, 29.3, 210.0)
local COUNSELOR_COORDS = vector4(-521.80, -244.80, 35.1, 305.0)

local BROKER_MODEL    = 'a_m_m_business_01'
local COUNSELOR_MODEL = 'a_m_y_business_02'

local brokerPed, counselorPed = nil, nil
local cachedVariants = nil

local function HasOxLib()
    return type(lib) == 'table' and type(lib.registerContext) == 'function'
end

local function HasOxTarget()
    return exports and exports.ox_target ~= nil
end


local function LoadModelSync(modelName)
    local hash = joaat(modelName)
    if not IsModelValid(hash) then return nil end
    RequestModel(hash)
    local waited = 0
    while not HasModelLoaded(hash) and waited < 5000 do
        Wait(25)
        waited = waited + 25
    end
    if not HasModelLoaded(hash) then return nil end
    return hash
end

-- ---------------------------------------------------------------------
-- Stationary ped spawner — GRAVITY-BASED placement.
-- Raycast YOK, PlaceObjectOnGroundProperly YOK. NPC 1m havadan bırakılır,
-- GTA fizik motoru gerçek zemine düşürür, sonra kilitlenir.
-- ---------------------------------------------------------------------
local function SpawnStationaryPed(coords, modelName)
    if type(coords) ~= 'vector4' then return nil end
    local hash = LoadModelSync(modelName)
    if not hash then return nil end

    -- ★ [PLAYTEST HOTFIX] Eskiden GetGroundZFor_3dCoord, ped oluşturulmadan/
    -- collision yüklenmeden ÖNCE çağrılıyordu -- onClientResourceStart'ta
    -- oyuncu bu koordinattan uzakta olduğunda çevre collision'ı henüz
    -- yüklenmemiş oluyor, GetGroundZFor_3dCoord "found=false" dönüyor ve
    -- config'teki ELLE YAZILMIŞ (yaklaşık 2-3m yüksek) Z değeri ham haliyle
    -- kullanılıyordu. PlaceObjectOnGroundProperly de zaten hatalı yükseklikte
    -- spawn olmuş ped'i güvenilir şekilde düzeltemiyordu. Şimdi: ped önce
    -- config Z'sinde oluşturulur, collision yüklenmesi (HasCollisionLoadedAroundEntity
    -- -- entity gerektirir, bu yüzden ped'den ÖNCE sorgulanamaz) beklenir,
    -- ANCAK ONDAN SONRA zemin Z'si TEKRAR sorgulanıp ped doğrudan o Z'ye
    -- taşınır.
    local ped = CreatePed(4, hash, coords.x, coords.y, coords.z, coords.w, false, true)
    if not ped or ped == 0 or not DoesEntityExist(ped) then
        SetModelAsNoLongerNeeded(hash)
        return nil
    end

    SetEntityAsMissionEntity(ped, true, true)
    SetPedCanRagdoll(ped, false)
    SetEntityCanBeDamaged(ped, false)
    SetPedCombatAttributes(ped, 17, true)

    -- ★ [IDLE FIX] Kaçma / combat AI tamamen kapat
    SetPedFleeAttributes(ped, 0, false)
    SetBlockingOfNonTemporaryEvents(ped, true)
    SetPedConfigFlag(ped, 292, true)   -- BF_DisableFleeing
    SetPedConfigFlag(ped, 17,  false)  -- BF_CanFightArmedPedsWhenNotArmed kapat
    SetPedConfigFlag(ped, 58,  true)   -- BF_DisableTakedown
    SetPedCanSwitchWeapon(ped, false)
    SetPedDropsWeaponsWhenDead(ped, false)
    ClearPedTasksImmediately(ped)

    RequestCollisionAtCoord(coords.x, coords.y, coords.z)
    local cWait = 0
    while not HasCollisionLoadedAroundEntity(ped) and cWait < 4000 do
        Wait(25)
        cWait = cWait + 25
    end

    -- ★ Collision artık yüklü -- zemin Z'sini GÜVENİLİR şekilde sorgula ve
    -- ped'i doğrudan oraya taşı (config'teki elle yazılmış Z'ye güvenme).
    local found, groundZ = GetGroundZFor_3dCoord(coords.x, coords.y, coords.z + 5.0, false)
    if found then
        SetEntityCoords(ped, coords.x, coords.y, groundZ + 0.5, false, false, false, false)
    end

    -- ★ Fizik + zemin snap (son ince ayar)
    PlaceObjectOnGroundProperly(ped)

    Wait(2000)

    FreezeEntityPosition(ped, true)
    SetEntityInvincible(ped, true)
    SetEntityHeading(ped, coords.w)

    SetModelAsNoLongerNeeded(hash)
    return ped
end

local function OpenBrokerMenu()
    if not HasOxLib() then return end

    if not cachedVariants then
        local ok, v = pcall(function()
            return lib.callback.await('matrix:callback:session1:getVariants', false)
        end)
        cachedVariants = (ok and type(v) == 'table') and v or {}
    end

    local myCoords   = GetEntityCoords(PlayerPedId())
    local brokerPos  = vector3(BROKER_COORDS.x, BROKER_COORDS.y, BROKER_COORDS.z)
    if #(myCoords - brokerPos) > 2.5 then
        lib.notify({
            title       = 'SECURITY HANDSHAKE',
            description = 'Line disconnected — out of proxy broker range.',
            type        = 'error',
        })
        return
    end

    local function BuildOption(size)
        local v = cachedVariants[size]
        if not v then return nil end
        return {
            title = ('[CELL // %s]'):format(size:upper()),
            description = ('Op cost $%d | Grid %.1f | Odor %.1f | Daily $%d')
                :format(v.cost, v.grid_load, v.odor_mult, v.daily_maintenance),
            icon = 'fa-solid fa-vault',
            onSelect = function()
                local confirm = lib.alertDialog({
                    header   = 'PROXY ASSET REGISTRATION',
                    content  = ('Register a %s cell at $%d? FinCEN audit monitors daily.')
                        :format(size:upper(), v.cost),
                    centered = true,
                    cancel   = true,
                })
                if confirm ~= 'confirm' then return end
                -- ★ [WAYPOINT FIX] Cell kurulumu oyuncunun waypoint'ine göre
                -- yapılır. Waypoint yoksa oyuncunun konumu kullanılır.
                local c = GetEntityCoords(PlayerPedId())
                local coordX, coordY = c.x, c.y

                local wpBlip = GetFirstBlipInfoId(8)   -- waypoint
                if DoesBlipExist(wpBlip) then
                    local wpCoord = GetBlipCoords(wpBlip)
                    coordX, coordY = wpCoord.x, wpCoord.y
                end

                TriggerServerEvent('matrix:server:proxy:purchaseCell', size, {
                    x = coordX, y = coordY, z = c.z,
                })
            end,
        }
    end

    lib.registerContext({
        id      = 'matrix_session1_broker',
        title   = 'PARAVAN ESTATE // ASSET MENU',
        options = {
            BuildOption('small'),
            BuildOption('medium'),
            BuildOption('large'),
        },
    })
    lib.showContext('matrix_session1_broker')
end

local function OpenCounselorMenu()
    if not HasOxLib() then return end

    local myCoords      = GetEntityCoords(PlayerPedId())
    local counselorPos  = vector3(COUNSELOR_COORDS.x, COUNSELOR_COORDS.y, COUNSELOR_COORDS.z)
    if #(myCoords - counselorPos) > 2.5 then
        lib.notify({
            title       = 'SECURITY HANDSHAKE',
            description = 'Line disconnected — counselor unavailable at this range.',
            type        = 'error',
        })
        return
    end

    lib.registerContext({
        id    = 'matrix_session1_counselor',
        title = 'CORRUPTED COUNSELOR // RETAINER',
        options = {
            {
                title       = '[RETAINMENT FUND — $50,000 CASH]',
                description = 'Expands legal umbrella. Caps operational cell limit at 3.',
                icon        = 'fa-solid fa-gavel',
                onSelect    = function()
                    local confirm = lib.alertDialog({
                        header   = 'COUNSELOR RETAINER',
                        content  = 'Execute the retainer fund transfer? $50,000 physical cash will be collected. Legal umbrella expands immediately.',
                        centered = true,
                        cancel   = true,
                    })
                    if confirm ~= 'confirm' then return end
                    TriggerServerEvent('matrix:server:proxy:counselorBribe')
                end,
            },
        },
    })
    lib.showContext('matrix_session1_counselor')
end

local function BindTargets()
    if not HasOxTarget() then return end

    if brokerPed and DoesEntityExist(brokerPed) then
        exports.ox_target:addLocalEntity(brokerPed, {
            {
                name     = 'matrix_session1_broker',
                icon     = 'fa-solid fa-building-columns',
                label    = 'Browse Cell Structures',
                distance = 1.8,
                onSelect = OpenBrokerMenu,
            },
        })
    end

    if counselorPed and DoesEntityExist(counselorPed) then
        exports.ox_target:addLocalEntity(counselorPed, {
            {
                name     = 'matrix_session1_counselor',
                icon     = 'fa-solid fa-scale-balanced',
                label    = 'Consult Counselor',
                distance = 1.8,
                onSelect = OpenCounselorMenu,
            },
        })
    end
end

-- ★ [STACKING FIX] Crash/restart sonrası kalan eski broker/counselor ped'leri
-- temizle. Oyuncu ped'i asla silinmez. Sadece kendi modellerimizi tara.
local function CleanupStaleSession1Peds()
    local brokerHash    = joaat(BROKER_MODEL)
    local counselorHash = joaat(COUNSELOR_MODEL)
    local myPed         = PlayerPedId()
    local cleaned       = 0
    for _, ped in ipairs(GetGamePool('CPed')) do
        if ped ~= myPed and DoesEntityExist(ped) then
            local m = GetEntityModel(ped)
            if m == brokerHash or m == counselorHash then
                DeleteEntity(ped)
                cleaned = cleaned + 1
            end
        end
    end
    if cleaned > 0 then
        print(('[SESSION1] stale ped cleanup: %d'):format(cleaned))
    end
end

-- ★ [COUNSELOR RETRY FIX] Ped spawn 3 kez denenir, her seferinde 1sn.
local function SpawnPedWithRetry(coords, modelName, maxAttempts)
    maxAttempts = maxAttempts or 3
    for attempt = 1, maxAttempts do
        local ped = SpawnStationaryPed(coords, modelName)
        if ped and ped ~= 0 and DoesEntityExist(ped) then
            return ped
        end
        print(('[SESSION1] %s spawn FAIL attempt %d'):format(modelName, attempt))
        Wait(1000)
    end
    print(('[SESSION1] [WARN] %s spawn edilemedi %d denemede'):format(modelName, maxAttempts))
    return nil
end

-- ★ [IDLE FIX] Broker/Counselor 500ms'de bir kontrol — kaçıyorsa reset.
local function StartBrokerIdleWatchdog()
    CreateThread(function()
        while true do
            Wait(500)
            for _, ped in ipairs({ brokerPed, counselorPed }) do
                if ped and DoesEntityExist(ped) then
                    if IsPedFleeing(ped) or IsPedRunning(ped)
                       or IsPedInMeleeCombat(ped) or IsPedRagdoll(ped) then
                        ClearPedTasksImmediately(ped)
                        FreezeEntityPosition(ped, true)
                        SetEntityHeading(ped, BROKER_COORDS.w)
                    end
                    TaskStandStill(ped, -1)
                end
            end
        end
    end)
end

local function InitReconWatchdog()
    brokerPed    = SpawnPedWithRetry(BROKER_COORDS,    BROKER_MODEL,    3)
    counselorPed = SpawnPedWithRetry(COUNSELOR_COORDS, COUNSELOR_MODEL, 3)

    if brokerPed    then SetPedDefaultComponentVariation(brokerPed)    end
    if counselorPed then SetPedDefaultComponentVariation(counselorPed) end

    BindTargets()
    StartBrokerIdleWatchdog()
end

AddEventHandler('onClientResourceStart', function(resName)
    if resName ~= GetCurrentResourceName() then return end
    CreateThread(function()
        Wait(1500)
        CleanupStaleSession1Peds()
        InitReconWatchdog()
    end)
end)

AddEventHandler('onClientResourceStop', function(resName)
    if resName ~= GetCurrentResourceName() then return end
    if HasOxTarget() then
        if brokerPed and DoesEntityExist(brokerPed) then
            pcall(function() exports.ox_target:removeLocalEntity(brokerPed) end)
        end
        if counselorPed and DoesEntityExist(counselorPed) then
            pcall(function() exports.ox_target:removeLocalEntity(counselorPed) end)
        end
    end
    if brokerPed    and DoesEntityExist(brokerPed)    then DeleteEntity(brokerPed)    end
    if counselorPed and DoesEntityExist(counselorPed) then DeleteEntity(counselorPed) end
    brokerPed, counselorPed = nil, nil
end)