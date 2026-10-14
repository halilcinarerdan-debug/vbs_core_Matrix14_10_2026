-- =====================================================================
-- MATRIX MUHAFIZ/KURYE TAKİPÇİLERİ / client/mercenary_followers.lua
-- v17.1 — IŞINLANMA FIX + Raycast Spawn + F10 Hijack İmha
-- =====================================================================

if not Config.Mercenary or not Config.Mercenary.EnablePhysicalFollowers then return end

local Followers = {}
local sanctionedPeds = {}
local _baselinePlayerGroupPeds = {}
local _playerGroupHash = GetHashKey('PLAYER')

local function _markSanctioned(ped)
    if ped and ped ~= 0 and DoesEntityExist(ped) then
        sanctionedPeds[ped] = true
    end
end

local function _raycastGroundZ(x, y, zHint, ignoreEntity)
    local startZ = (zHint or 0.0) + 10.0
    local endZ   = (zHint or 0.0) - 20.0
    local ray = StartExpensiveSynchronousShapeTestLosProbe(
        x, y, startZ,
        x, y, endZ,
        1, ignoreEntity or 0, 0
    )
    Wait(0)
    local _, hit, _, _, hitZ = GetShapeTestResult(ray)
    if hit and type(hitZ) == 'number' and hitZ == hitZ then
        return hitZ
    end
    return zHint or 0.0
end

local function DeleteFollower(entry)
    if entry and entry.ped and DoesEntityExist(entry.ped) then
        sanctionedPeds[entry.ped] = nil
        SetEntityAsNoLongerNeeded(entry.ped)
        if DoesEntityExist(entry.ped) then
            pcall(DeletePed, entry.ped)
        end
    end
end

local function SpawnFollowerPed(coords, heading)
    local model = GetHashKey(Config.Mercenary.PedModel or 'g_m_y_mexgoon_02')
    RequestModel(model)
    local waited = 0
    while not HasModelLoaded(model) and waited < 3000 do
        Wait(50)
        waited = waited + 50
    end
    if not HasModelLoaded(model) then
        SetModelAsNoLongerNeeded(model)
        return nil
    end

    local ped = CreatePed(4, model, coords.x, coords.y, coords.z, heading or 0.0, true, true)
    if not DoesEntityExist(ped) then
        SetModelAsNoLongerNeeded(model)
        return nil
    end

    SetEntityAsMissionEntity(ped, true, true)
    SetPedFleeAttributes(ped, 0, false)
    SetPedCombatAttributes(ped, 46, true)
    SetPedCombatAbility(ped, 2)
    SetPedCombatRange(ped, 2)
    SetPedAccuracy(ped, 65)
    GiveWeaponToPed(ped, GetHashKey('WEAPON_COMBATPISTOL'), 250, false, true)
    SetPedAsGroupMember(ped, GetPlayerGroup(PlayerId()))
    SetPedRelationshipGroupHash(ped, _playerGroupHash)
    SetModelAsNoLongerNeeded(model)

    return ped
end

-- ★ v17.1: ARTIK RAYCAST İLE ZEMİN Z BULUNUYOR
-- Ped havada doğmuyor, yere düşerken yanına gelmiyor
local function ComputeReverseForwardSpawn(playerPed, index)
    local baseCoords = GetEntityCoords(playerPed)
    local forward    = GetEntityForwardVector(playerPed)
    local radius     = Config.Mercenary.SummonRadius or 3.5
    local sideOffset = ((index % 2 == 0) and 1.0 or -1.0) * (radius * 0.5)

    local spawnX = baseCoords.x - (forward.x * radius) + sideOffset
    local spawnY = baseCoords.y - (forward.y * radius)

    -- ★ ZEMİN Z RAYCAST — havada doğmasın
    local spawnZ = _raycastGroundZ(spawnX, spawnY, baseCoords.z, playerPed)

    -- ★ Collision bekle
    RequestCollisionAtCoord(spawnX, spawnY, spawnZ)
    local tries = 0
    while not HasCollisionLoadedAroundEntity(playerPed) and tries < 20 do
        Wait(25)
        tries = tries + 1
    end

    -- ★ Ekstra settle — GTA motorunun zemini oturtması için
    Wait(150)

    return vector3(spawnX, spawnY, spawnZ)
end

RegisterNetEvent('matrix:client:mercenary:summonApproved', function(payload)
    -- ★ YENİ PAYLOAD FORMATI: tablo { bot_id, bot_name, dna_id, role, new_count }
    -- Geriye dönük: sayı gelirse eski davranış
    local botId, botName, dnaId, newCount
    if type(payload) == 'table' then
        botId    = payload.bot_id
        botName  = payload.bot_name or ('Ajan-%s'):format(tostring(botId or '?'))
        dnaId    = payload.dna_id
        newCount = payload.new_count or (#Followers + 1)
    elseif type(payload) == 'number' then
        newCount = payload
    else
        return
    end

    local playerPed = PlayerPedId()
    local spawnCoords = ComputeReverseForwardSpawn(playerPed, #Followers + 1)
    local heading     = (GetEntityHeading(playerPed) + 180.0) % 360.0

    local ped = SpawnFollowerPed(spawnCoords, heading)
    if not ped then
        if lib and lib.notify then
            lib.notify({ title = '[MUHAFIZ]', description = 'Takipci doğurulamadi.', type = 'error' })
        end
        return
    end

    _markSanctioned(ped)

    Followers[#Followers + 1] = {
        ped          = ped,
        entering     = false,
        spawned_at   = GetGameTimer(),
        settle_until = GetGameTimer() + 800,
        bot_id       = botId,
        bot_name     = botName,
        dna_id       = dnaId,
    }

    if lib and lib.notify then
        lib.notify({
            title = '[AJAN SAHAYA INDIRILDI]',
            description = ('%s -> sahadaki takipci: %d/%d'):format(
                botName or 'Ajan', newCount, Config.Mercenary.MaxFollowers or 2),
            type = 'success'
        })
    end
end)

local function DismissAllFollowers()
    for _, entry in ipairs(Followers) do
        DeleteFollower(entry)
    end
    Followers = {}
    TriggerServerEvent('matrix:server:mercenary:reportDismiss', 0)
    if lib and lib.notify then
        lib.notify({ title = '[MUHAFIZ]', description = 'Tum takipciler serbest birakildi.', type = 'inform' })
    end
end

-- ★ v17.1: RegisterKeyMapping KALDIRILDI
-- Sebep: hud.lua'daki onClientResourceStart'ta G tuşu bind'leniyor.
-- İki yerde bind etmek çakışma yaratıyordu.
RegisterCommand('muhafizcagir', function()
    TriggerServerEvent('matrix:server:mercenary:requestSummon')
end, false)

RegisterCommand('muhafizsalla', function()
    DismissAllFollowers()
end, false)

local function TryEnterVehicleSeats(vehicle)
    if not DoesEntityExist(vehicle) then return end
    local maxSeats = GetVehicleMaxNumberOfPassengers(vehicle)

    for _, entry in ipairs(Followers) do
        if entry.ped and DoesEntityExist(entry.ped) and not entry.entering then
            local alreadyInVehicle = IsPedInVehicle(entry.ped, vehicle, false)
            if not alreadyInVehicle then
                local freeSeat = nil
                for seat = -1, maxSeats - 1 do
                    if IsVehicleSeatFree(vehicle, seat) then freeSeat = seat; break end
                end
                if freeSeat then
                    entry.entering = true
                    TaskEnterVehicle(entry.ped, vehicle, 8000, freeSeat, 1.0, 1, 0)
                end
            end
        end
    end
end

local function DefendPlayerIfThreatened(playerPed)
    local playerCoords = GetEntityCoords(playerPed)
    local handle, ped = FindFirstPed()
    local found = true
    local threat = nil

    repeat
        if ped ~= playerPed and DoesEntityExist(ped) and not IsPedAPlayer(ped)
            and GetPedRelationshipGroupHash(ped) ~= _playerGroupHash
            and IsPedInCombat(ped, playerPed) then
            local d = #(GetEntityCoords(ped) - playerCoords)
            if d <= (Config.Mercenary.CombatAggroRadius or 35.0) then
                threat = ped
                break
            end
        end
        found, ped = FindNextPed(handle)
    until not found
    EndFindPed(handle)

    if threat then
        for _, entry in ipairs(Followers) do
            if entry.ped and DoesEntityExist(entry.ped) and not IsPedInCombat(entry.ped, threat) then
                TaskCombatPed(entry.ped, threat, 0, 16)
            end
        end
    end
end

local function DrawText3D(coords, text, r, g, b, scale)
    local onScreen, sx, sy = GetScreenCoordFromWorldCoord(coords.x, coords.y, coords.z)
    if not onScreen then return end
    SetTextFont(4)
    SetTextProportional(1)
    SetTextScale(scale or 0.28, scale or 0.28)
    SetTextColour(r or 235, g or 235, b or 235, 235)
    SetTextDropshadow(1, 0, 0, 0, 220)
    SetTextEdge(1, 0, 0, 0, 180)
    SetTextEntry('STRING')
    AddTextComponentString(text)
    DrawText(sx, sy)
end

local function ComputeFollowerMode(entry, playerPed, playerVehicle)
    if not entry.ped or not DoesEntityExist(entry.ped) then return 'hold' end
    if entry.entering then return 'follow' end
    if IsPedInCombat(entry.ped, playerPed) or IsPedShooting(entry.ped) then return 'guard' end
    if playerVehicle and playerVehicle ~= 0 then return 'follow' end
    return 'hold'
end

local function ComputeFollowerStatus(entry)
    local ped = entry.ped
    if not ped or not DoesEntityExist(ped) then return nil, false end
    local health = GetEntityHealth(ped)
    local maxHealth = GetEntityMaxHealth(ped)
    if maxHealth <= 0 then maxHealth = 200 end
    local ratio = health / maxHealth
    if ratio < 0.35 then
        return '[KRİTİK: ARTER KANAMASI — ACİL TURNİKE ŞART!]', true
    end
    return '[DURUM: STABİL]', false
end

local MODE_LABELS = {
    follow = '[GÖREV: TAKİPTE]',
    hold   = '[GÖREV: MEVZİDE — BEKLEMEDE]',
    guard  = '[GÖREV: ÇAPRAZ ATEŞTE — NOKTAYI KORUYOR]',
}

CreateThread(function()
    while true do
        local anyClose = false
        if #Followers > 0 then
            local playerPed = PlayerPedId()
            local playerCoords = GetEntityCoords(playerPed)
            local playerVehicle = IsPedInAnyVehicle(playerPed, false) and GetVehiclePedIsIn(playerPed, false) or nil

            for _, entry in ipairs(Followers) do
                if entry.ped and DoesEntityExist(entry.ped) then
                    local pedCoords = GetEntityCoords(entry.ped)
                    local dist = #(pedCoords - playerCoords)
                    if dist <= 15.0 then
                        anyClose = true
                        local headCoords = vector3(pedCoords.x, pedCoords.y, pedCoords.z + 1.05)
                        local mode   = ComputeFollowerMode(entry, playerPed, playerVehicle)
                        local statusText, isCritical = ComputeFollowerStatus(entry)
                        local sicil = entry.bot_name or ('Ajan-%s'):format(tostring(entry.ped):sub(-4))

                        DrawText3D(headCoords, ('[SİCİL: %s]'):format(sicil), 235, 235, 235, 0.30)
                        DrawText3D(vector3(headCoords.x, headCoords.y, headCoords.z - 0.16),
                            MODE_LABELS[mode] or MODE_LABELS.hold, 200, 255, 210, 0.28)
                        if statusText then
                            local r, g, b = 200, 255, 210
                            if isCritical then r, g, b = 255, 70, 70 end
                            DrawText3D(vector3(headCoords.x, headCoords.y, headCoords.z - 0.32),
                                statusText, r, g, b, 0.28)
                        end
                    end
                end
            end
        end
        Wait(anyClose and 0 or 150)
    end
end)
-- ★ v17.1: IŞINLANMA FIX
--   1) settle_until kontrolü — yeni spawn olan ped 800ms boyunca TaskGoToEntity ALMAZ
--   2) TeleportDistance aşılırsa ped oyuncunun ÜZERİNE değil 4m ARKASINA ışınlanır
--   3) FollowDistance 4.5m'ye çekildi (dibine yapışmasın)
CreateThread(function()
    while true do
        Wait(Config.Mercenary.CheckIntervalMs or 1500)

        if #Followers > 0 then
            local playerPed = PlayerPedId()
            local playerCoords = GetEntityCoords(playerPed)
            local vehicle = IsPedInAnyVehicle(playerPed, false) and GetVehiclePedIsIn(playerPed, false) or nil
            local now = GetGameTimer()

            for i = #Followers, 1, -1 do
                local entry = Followers[i]
                if not entry.ped or not DoesEntityExist(entry.ped) then
                    table.remove(Followers, i)
                elseif IsEntityDead(entry.ped) then
                    DeleteFollower(entry)
                    table.remove(Followers, i)
                    TriggerServerEvent('matrix:server:mercenary:reportDismiss', #Followers)
                else
                    -- ★ SETTLE: yeni spawn olan ped bekleme süresini geçmediyse
                    -- TaskGoToEntity ÇAĞRILMAZ, oturması beklenir
                    if entry.settle_until and now < entry.settle_until then
                        -- Settle süresince sadece ışınlanma kontrolü
                    else
                        entry.settle_until = nil

                        local followerCoords = GetEntityCoords(entry.ped)
                        local dist = #(followerCoords - playerCoords)

                        if dist > (Config.Mercenary.TeleportDistance or 80.0) then
                            -- ★ v17.1: ÜZERİNE DEĞİL, 4m ARKASINA IŞINLA
                            local back = ComputeReverseForwardSpawn(playerPed, i)
                            SetEntityCoords(entry.ped, back.x, back.y, back.z, false, false, false, false)
                            entry.settle_until = now + 500  -- Işınlanma sonrası da settle
                        elseif vehicle then
                            entry.entering = false
                            TryEnterVehicleSeats(vehicle)
                        elseif not IsPedInAnyVehicle(entry.ped, false) then
                            -- ★ v17.1: 4.5m'den uzaksa takip et
                            local followDist = (Config.Mercenary.FollowDistance or 3.0) + 1.5
                            if dist > followDist then
                                TaskGoToEntity(entry.ped, playerPed, -1, followDist, 2.0, 1073741824, 0)
                            end
                        end
                    end
                end
            end

            if #Followers > 0 then
                DefendPlayerIfThreatened(playerPed)
            end
        end
    end
end)

CreateThread(function()
    Wait(2500)
    local handle, ped = FindFirstPed()
    local found = true
    repeat
        if ped and ped ~= 0 and DoesEntityExist(ped) and not IsPedAPlayer(ped) then
            if GetPedRelationshipGroupHash(ped) == _playerGroupHash then
                _baselinePlayerGroupPeds[ped] = true
            end
        end
        found, ped = FindNextPed(handle)
    until not found
    EndFindPed(handle)
end)

CreateThread(function()
    Wait(3000)
    while true do
        Wait(75)
        local playerPed = PlayerPedId()
        local toDelete = {}
        local handle, ped = FindFirstPed()
        local found = true

        repeat
            if ped and ped ~= playerPed and ped ~= 0 and DoesEntityExist(ped) and not IsPedAPlayer(ped) then
                if GetPedRelationshipGroupHash(ped) == _playerGroupHash then
                    local isOurs  = sanctionedPeds[ped] == true
                    local isBasel = _baselinePlayerGroupPeds[ped] == true
                    if not isOurs and not isBasel then
                        toDelete[#toDelete + 1] = ped
                    end
                end
            end
            found, ped = FindNextPed(handle)
        until not found
        EndFindPed(handle)

        for _, p in ipairs(toDelete) do
            if DoesEntityExist(p) then
                pcall(SetEntityAsMissionEntity, p, false, false)
                pcall(SetEntityAsNoLongerNeeded, p)
                pcall(DeletePed, p)
                _baselinePlayerGroupPeds[p] = nil
            end
        end

        if #toDelete > 0 then
            TriggerServerEvent('matrix:server:mercenary:reportSummonTamper', #toDelete)
        end
    end
end)

AddEventHandler('onResourceStop', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end
    for _, entry in ipairs(Followers) do
        DeleteFollower(entry)
    end
    Followers = {}
    sanctionedPeds = {}
    _baselinePlayerGroupPeds = {}
end)