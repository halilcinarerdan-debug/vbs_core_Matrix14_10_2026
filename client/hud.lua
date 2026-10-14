-- =====================================================================
-- MATRIX HUD / client/hud.lua  (KATMAN 7 v18.0 — PHASE 6 STEP 3)
-- F10 → PAGE_UP, CancelEvent kalkanı, tüm bültenler, forensic ops,
-- rendezvous notepad, fleet bulletin, HYDRAULIC PRESS + BOTANY HUD.
-- =====================================================================

local hudActive = false
local hudLines  = {}
local NotepadEntries = {}
local MAX_NOTEPAD_ENTRIES = 32

local function AddNotepadEntry(text)
    NotepadEntries[#NotepadEntries + 1] = { text = text }
    while #NotepadEntries > MAX_NOTEPAD_ENTRIES do table.remove(NotepadEntries, 1) end
end

-- ★ [YENİ] Haritada (pause menu map) elle bırakılan GPS işareti otomatik
-- olarak Not Defteri'ne koordinatla yazılır. Native bir "waypoint changed"
-- event'i yok, bu yüzden 1sn'de bir GetFirstBlipInfoId(8) (waypoint
-- blip sprite'ı) ile poll edilir; koordinat bir öncekinden >1.0m
-- farklıysa yeni işaret sayılır.
local _lastWaypointCoords = nil

CreateThread(function()
    while true do
        Wait(1000)
        if IsWaypointActive() then
            local blip = GetFirstBlipInfoId(8)
            if DoesBlipExist(blip) then
                local coords = GetBlipCoords(blip)
                if not _lastWaypointCoords or #(coords - _lastWaypointCoords) > 1.0 then
                    _lastWaypointCoords = coords
                    AddNotepadEntry(('[HARİTA İŞARETİ] %.2f, %.2f, %.2f'):format(coords.x, coords.y, coords.z))
                    if lib and lib.notify then
                        lib.notify({ title = '[NOT DEFTERİ]', description = 'Harita işareti not defterine eklendi.', type = 'inform' })
                    end
                end
            end
        else
            _lastWaypointCoords = nil
        end
    end
end)

-- ★ [YENİ] /coords artık client-side: koordinatı hem chat'e basar hem de
-- Not Defteri'ne ekler (haritadaki işaretlerle AYNI mekanizma). Eski
-- server/main.lua'daki /coords kaldırıldı -- ayni isimle client-side
-- kayıtlı bir komut varsa chat girdisini SUNUCUYA HİÇ İLETMEZ, o yüzden
-- iki tarafta birden tutmak yalnızca kafa karıştırırdı.
RegisterCommand('coords', function()
    local ped = PlayerPedId()
    local c   = GetEntityCoords(ped)
    local hd  = GetEntityHeading(ped)

    -- ★ Panoya otomatik kopyala
    local coordStr = ('%.3f, %.3f, %.3f'):format(c.x, c.y, c.z)
    lib.setClipboard(coordStr)

    TriggerEvent('chat:addMessage', { args = { '[COORDS]', ('KOMUTLAR ICIN (boslukla): %.3f %.3f %.3f  |Heading:%.1f'):format(c.x, c.y, c.z, hd) } })
    TriggerEvent('chat:addMessage', { args = { '[COORDS]', ('CONFIG ICIN (virgullu):  vector3(%.3f, %.3f, %.3f)'):format(c.x, c.y, c.z) } })

    AddNotepadEntry(('[/coords] %.3f, %.3f, %.3f (heading %.1f)'):format(c.x, c.y, c.z, hd))
    if lib and lib.notify then
        lib.notify({ title = '[NOT DEFTERİ]', description = ('Koordinat panoya kopyalandı ve deftere eklendi: %s'):format(coordStr), type = 'success' })
    end
end, false)

local COLOR_HEADER = { 235, 235, 235 }
local COLOR_VALUE  = { 110, 255, 140 }
local COLOR_DIM    = { 90, 140, 100 }
local COLOR_DANGER = { 255, 70, 70 }

local HUD_BASE_X      = 0.015
local HUD_BASE_Y      = 0.04
local HUD_LINE_HEIGHT = 0.021
local HUD_TEXT_SCALE  = 0.33
local HUD_FRAME_TEXT  = '========================================'

local MAX_HUD_LINES  = (Config.Hud and Config.Hud.MaxHudLines) or 64
local MAX_PLATE_LEN  = (Config.Hud and Config.Hud.MaxPlateInputLength) or 32
local MAX_BOT_ID     = (Config.Hud and Config.Hud.MaxBotIdInputValue) or 999999
local MAX_WAYPOINT_LEN = (Config.Hud and Config.Hud.MaxWaypointInputLength) or 64
local WEAPON_EVAC_MS = ((Config.Forensics and Config.Forensics.WeaponEvacuationSeconds) or 6) * 1000

-- ★ PHASE6-STEP3 — Hydraulic Press / Botany telemetry state
local HYDRAULIC_STASH_CAP_KG   = 150.0
local HYDRAULIC_BAGS_PER_BRICK = 100
local HYDRAULIC_PRODUCT_OPTIONS = {
    { value = 'meth_bag',                 label = 'Metamfetamin (10g poset)' },
    { value = 'coke_brick',               label = 'Kokain (10g poset)' },
    { value = 'masterpiece_gourmet_weed', label = 'Bas Yapiti Esrar (10g poset)' },
}
local hydraulicTelemetry = {
    brick_press_status      = 'idle',
    total_compressed_bricks = 0,
    botany_growth_percent   = 0.0,
    stash_filled_kg         = 0.0,
    stash_cap_kg            = HYDRAULIC_STASH_CAP_KG,
}

-- ★ [YENİ] Toplu Satış Hub (District Hub) HUD telemetrisi
local districtHubTelemetry = {
    hubs = {}, -- { { id, label, trap_house_id, coords=vector3, active, locked }, ... }
}

local function DrawMonoLine(x, y, text, r, g, b, scale)
    SetTextFont(4)
    SetTextProportional(1)
    SetTextScale(scale, scale)
    SetTextColour(r, g, b, 235)
    SetTextDropshadow(1, 0, 0, 0, 200)
    SetTextEdge(1, 0, 0, 0, 180)
    SetTextEntry('STRING')
    AddTextComponentString(text)
    DrawText(x, y)
end

local function SanitizeNumericArg(v, minVal, maxVal)
    if v == nil then return nil end
    local n = tonumber(v)
    if not n or n ~= n or n == math.huge or n == -math.huge then return nil end
    n = math.floor(n)
    if n < (minVal or 1) or n > (maxVal or MAX_BOT_ID) then return nil end
    return tostring(n)
end

local function SanitizeFloatArg(v, minVal, maxVal)
    if v == nil then return nil end
    local n = tonumber(v)
    if not n or n ~= n or n == math.huge or n == -math.huge then return nil end
    if n < minVal or n > maxVal then return nil end
    return math.floor(n * 100.0 + 0.5) / 100.0
end

local function SanitizePlateArg(v)
    if v == nil then return '' end
    local s = tostring(v)
    if #s > MAX_PLATE_LEN then return nil end
    if s == '' then return '' end
    if s:find('[^%w%-_%.]') then return nil end
    return s
end

local VALID_RANK_ARGS = { Leader = true, Logistics_Officer = true, Chemist = true }
local function SanitizeRankArg(v)
    if v == nil then return nil end
    local s = tostring(v)
    if not VALID_RANK_ARGS[s] then return nil end
    return s
end

local DEAD_DROP_TOKEN_PATTERN = '^[Dd][Dd]%-(%d+)$'
local function SanitizeDeadDropArg(s)
    local idStr = s:match(DEAD_DROP_TOKEN_PATTERN)
    if not idStr then return nil end
    local id = tonumber(idStr)
    if not id then return nil end
    if not (Config.Supplier and Config.Supplier.DeadDrops) then return nil end
    for _, drop in ipairs(Config.Supplier.DeadDrops) do
        if drop.id == id then return ('DD-%d'):format(id) end
    end
    return nil
end

local function SanitizeWaypointArg(v)
    if v == nil then return nil end
    local s = tostring(v)
    s = s:match('^%s*(.-)%s*$')
    if s == '' then return nil end
    if #s > MAX_WAYPOINT_LEN then return nil end
    local ddToken = SanitizeDeadDropArg(s)
    if ddToken then return ddToken end
    if s:find('[^%d%.,%-%s]') then return nil end
    s = s:gsub('%s+', ','):gsub(',+', ',')
    s = s:match('^,*(.-),*$')
    if s == '' then return nil end
    if #s > MAX_WAYPOINT_LEN then return nil end
    return s
end

local ROUTE_WAYPOINT_SKIP = 'nil'
local function SanitizeOptionalWaypointArg(v)
    if v == nil then return ROUTE_WAYPOINT_SKIP end
    local trimmed = tostring(v):match('^%s*(.-)%s*$')
    if trimmed == '' then return ROUTE_WAYPOINT_SKIP end
    return SanitizeWaypointArg(trimmed)
end

local function SanitizeVehicleTypeArg(v)
    if v == nil then return nil end
    local s = tostring(v)
    if not (Config.Logistics and Config.Logistics.VehicleTypes and Config.Logistics.VehicleTypes[s]) then
        return nil
    end
    return s
end

local function BuildVehicleTypeOptions()
    local options = {}
    for vtype in pairs(Config.Logistics and Config.Logistics.VehicleTypes or {}) do
        options[#options + 1] = { value = vtype, label = vtype }
    end
    table.sort(options, function(a, b) return a.value < b.value end)
    return options
end

local function NotifyInvalidInput(reason)
    if lib and lib.notify then
        lib.notify({
            title       = '[GECERSIZ GIRD]',
            description = reason or 'Komut icin gecersiz parametre.',
            type        = 'error'
        })
    else
        print(('[MATRIX:HUD] Gecersiz girdi: %s'):format(tostring(reason)))
    end
end

-- ★ [E1] SIFIR SAYI STANDARDI — Bültene Çeviri Motoru
local BULLETIN_CORTISOL   = (Config.Hud and Config.Hud.Bulletins and Config.Hud.Bulletins.Cortisol)
    or { CalmMax = 0.20, AnxietyMax = 0.60 }
local BULLETIN_FATIGUE    = (Config.Hud and Config.Hud.Bulletins and Config.Hud.Bulletins.Fatigue)
    or { FreshMax = 0.30, ChronicMax = 0.80 }
local BULLETIN_MECHANICAL = (Config.Hud and Config.Hud.Bulletins and Config.Hud.Bulletins.Mechanical)
    or { PristineMin = 0.80, WornMin = 0.40 }

local function FormatCortisolBulletin(value)
    value = tonumber(value)
    if not value then return nil end
    if value < BULLETIN_CORTISOL.CalmMax then
        return '[NABIZ: SOĞUKKANLI SUBAY]'
    elseif value <= BULLETIN_CORTISOL.AnxietyMax then
        return '[NABIZ: ANKSİYETE BAŞLANGICI — TETİKTE]'
    else
        return '[NABIZ: AKUT PANİK ATAK KRİZİ — ELLERİN TİTRİYOR]'
    end
end

local function FormatFatigueBulletin(value)
    value = tonumber(value)
    if not value then return nil end
    if value < BULLETIN_FATIGUE.FreshMax then
        return '[KONDİSYON: DİNÇ]'
    elseif value <= BULLETIN_FATIGUE.ChronicMax then
        return '[KONDİSYON: KRONİK BİTKİNLİK — REFLEKSLER YAVAŞ]'
    else
        return '[KONDİSYON: NÖRON HASARI SINIRI — BEYİN SAKATLIĞI RİSKİ]'
    end
end

local function FormatMechanicalBulletin(value)
    value = tonumber(value)
    if not value then return nil end
    if value > BULLETIN_MECHANICAL.PristineMin then
        return '[MEKANİK: KUSURSUZ CONDITION]'
    elseif value >= BULLETIN_MECHANICAL.WornMin then
        return '[MEKANİK: YİV-SET AŞINMASI — BALİSTİK MUTASYON AKTİF]'
    else
        return '[MEKANİK: KRİTİK YİV ERİMESİ — TUTUKLUK VE PERMADEATH RİSKİ]'
    end
end

local function FormatBulletinLine(metric, value, label)
    label = label or ''
    if metric == 'cortisol_level' then
        local text = FormatCortisolBulletin(value)
        return text and (label .. text) or nil
    elseif metric == 'fatigue_level' then
        local text = FormatFatigueBulletin(value)
        return text and (label .. text) or nil
    elseif metric == 'durability' or metric == 'wear_level' then
        local text = FormatMechanicalBulletin(value)
        return text and (label .. text) or nil
    end
    return nil
end

local function ToggleHud(forceState)
    local newState = (forceState ~= nil) and forceState or (not hudActive)
    if newState == hudActive then return end
    hudActive = newState
    if not hudActive then hudLines = {} end
    TriggerServerEvent('matrix:server:hudToggled', hudActive)
end

local function _SanitizeHudText(raw)
    if type(raw) ~= 'string' then return nil end
    local s = string.sub(raw, 1, 128)
    s = s:gsub('[%z\1-\31]', '')
    if s == '' then return nil end
    return s
end

RegisterNetEvent('matrix:client:hudSnapshot', function(lines)
    if not hudActive then return end
    if type(lines) ~= 'table' then return end
    if #lines > MAX_HUD_LINES then return end

    local converted = {}
    for i = 1, #lines do
        local line = lines[i]
        if type(line) == 'table' then
            if line.metric ~= nil then
                local text = FormatBulletinLine(line.metric, line.value, line.label)
                if text then
                    local safe = _SanitizeHudText(text)
                    if safe then
                        converted[#converted + 1] = { text = safe, header = line.header and true or false, danger = line.danger and true or false }
                    end
                end
            elseif type(line.text) == 'string' then
                local safe = _SanitizeHudText(line.text)
                if safe then
                    converted[#converted + 1] = { text = safe, header = line.header and true or false, danger = line.danger and true or false }
                end
            end
        end
    end
    hudLines = converted
end)

-- ★ PHASE6-STEP3 — Hydraulic telemetry receiver
RegisterNetEvent('matrix:client:hydraulicTelemetry', function(payload)
    if type(payload) ~= 'table' then return end
    hydraulicTelemetry.brick_press_status      = tostring(payload.brick_press_status or 'idle')
    hydraulicTelemetry.total_compressed_bricks = tonumber(payload.total_compressed_bricks) or 0
    hydraulicTelemetry.botany_growth_percent   = tonumber(payload.botany_growth_percent) or 0.0
    hydraulicTelemetry.stash_filled_kg         = tonumber(payload.stash_filled_kg) or 0.0
    hydraulicTelemetry.stash_cap_kg            = tonumber(payload.stash_cap_kg) or HYDRAULIC_STASH_CAP_KG
end)

-- ★ [YENİ] Toplu Satış Hub telemetri alıcısı
RegisterNetEvent('matrix:client:districtHubTelemetry', function(payload)
    if type(payload) ~= 'table' or type(payload.hubs) ~= 'table' then return end
    local hubs = {}
    for _, h in ipairs(payload.hubs) do
        if type(h) == 'table' and type(h.x) == 'number' and type(h.y) == 'number' and type(h.z) == 'number' then
            hubs[#hubs + 1] = {
                id            = h.id,
                label         = tostring(h.label or ('Hub #%s'):format(tostring(h.id))),
                trap_house_id = h.trap_house_id,
                coords        = vector3(h.x, h.y, h.z),
                active        = h.active and true or false,
                locked        = h.locked and true or false,
            }
        end
    end
    districtHubTelemetry.hubs = hubs
end)

-- ★ PHASE6-STEP3 — Telemetry pull thread (event-driven, 2s heartbeat while HUD is visible)
CreateThread(function()
    while true do
        Wait(2000)
        if hudActive then
            TriggerServerEvent('matrix:server:requestHydraulicTelemetry')
            TriggerServerEvent('matrix:server:requestDistrictHubTelemetry')
        end
    end
end)

local OpenBaronTerminaliMenu
local OpenCanliKadroMenu
local OpenBotActionsMenu
local OpenMatrixNotepad

-- ★ [FIX] Alt menuler (Canli Kadro/Not Defteri/Adli Islemler/Bulusma
-- Notepad'i) geri dönüş hedefi olarak sabit 'matrix_baron_terminali'
-- string'ini kullaniyordu, ama OpenBaronTerminaliMenu her acilista
-- _baronMenuCounter ile ID'yi 'matrix_baron_terminali_N' yapiyordu --
-- ikisi HICBIR ZAMAN eslesmiyordu, ox_lib "geri" hedefini bulamayinca
-- sessizce hicbir sey yapmiyordu (kullanici ESC'ye mecbur kaliyordu).
-- Bu dosyadaki tum menu fonksiyonlari (asagida, tanim sirasi fark
-- etmeksizin) bu tek upvalue'yu paylasir; alt menuler artik bunu okuyup
-- GERCEK guncel root ID'sine geri doner.
local _currentBaronMenuId = nil

-- ★ PHASE6-STEP3 forward declarations for the new dialogs
local OpenHydraulicPressDialog
local OpenBotanyEnvironmentDialog

-- ★ PHASE6-STEP3 — Telemetry line renderer (returns the new Y)
local function DrawHydraulicTelemetryBlock(y)
    local cap = hydraulicTelemetry.stash_cap_kg
    if cap <= 0 then cap = HYDRAULIC_STASH_CAP_KG end
    local ratio = hydraulicTelemetry.stash_filled_kg / cap
    if ratio < 0.0 then ratio = 0.0 end
    if ratio > 1.0 then ratio = 1.0 end
    local barW = 20
    local filled = math.floor(ratio * barW + 0.5)
    local bar = ('|'):rep(filled) .. ('.'):rep(barW - filled)

    local pressStatus = hydraulicTelemetry.brick_press_status
    local pressColor = COLOR_VALUE
    if pressStatus ~= 'idle' then pressColor = COLOR_HEADER end

    DrawMonoLine(HUD_BASE_X, y,
        ('[PRES: %s] BRICK: %d'):format(pressStatus, hydraulicTelemetry.total_compressed_bricks),
        pressColor[1], pressColor[2], pressColor[3], HUD_TEXT_SCALE)
    y = y + HUD_LINE_HEIGHT

    DrawMonoLine(HUD_BASE_X, y,
        ('[BOTANY: %.1f%% BUYUME]'):format(hydraulicTelemetry.botany_growth_percent),
        COLOR_VALUE[1], COLOR_VALUE[2], COLOR_VALUE[3], HUD_TEXT_SCALE)
    y = y + HUD_LINE_HEIGHT

    DrawMonoLine(HUD_BASE_X, y,
        ('[STASH: %.1f/%.1f kg] [%s] %.1f%%'):format(
            hydraulicTelemetry.stash_filled_kg, cap, bar, ratio * 100.0),
        COLOR_VALUE[1], COLOR_VALUE[2], COLOR_VALUE[3], HUD_TEXT_SCALE)
    y = y + HUD_LINE_HEIGHT

    return y
end

-- ★ [YENİ] Toplu Satış Hub durum satırı — en yakın aktif hub'ı mesafesiyle
-- gösterir + kaç aktif/toplam hub olduğunu özetler.
local function DrawDistrictHubBlock(y)
    local hubs = districtHubTelemetry.hubs
    if #hubs == 0 then return y end

    local myCoords = GetEntityCoords(PlayerPedId())
    local activeCount, totalCount = 0, #hubs
    local nearestLabel, nearestDist = nil, nil

    for _, hub in ipairs(hubs) do
        if hub.active then
            activeCount = activeCount + 1
            local dist = #(myCoords - hub.coords)
            if not nearestDist or dist < nearestDist then
                nearestDist  = dist
                nearestLabel = hub.label
            end
        end
    end

    local summary = ('[TOPLU SATIŞ] Aktif: %d/%d'):format(activeCount, totalCount)
    if nearestLabel then
        summary = summary .. (' | En Yakın: %s (%.0fm)'):format(nearestLabel, nearestDist)
    end

    DrawMonoLine(HUD_BASE_X, y, summary, COLOR_VALUE[1], COLOR_VALUE[2], COLOR_VALUE[3], HUD_TEXT_SCALE)
    y = y + HUD_LINE_HEIGHT
    return y
end

-- ★ [R1] ANA ÇİZİM DÖNGÜSÜ — per-frame render
CreateThread(function()
    while true do
        if hudActive then
            local y = HUD_BASE_Y
            DrawMonoLine(HUD_BASE_X, y, HUD_FRAME_TEXT, COLOR_DIM[1], COLOR_DIM[2], COLOR_DIM[3], HUD_TEXT_SCALE)
            y = y + HUD_LINE_HEIGHT
            DrawMonoLine(HUD_BASE_X, y, '[MATRIX TAKTIK DURUM HUD]', COLOR_HEADER[1], COLOR_HEADER[2], COLOR_HEADER[3], HUD_TEXT_SCALE)
            y = y + HUD_LINE_HEIGHT

            -- ★ PHASE6-STEP3 — Live industrial telemetry layer (always on top)
            y = DrawHydraulicTelemetryBlock(y)
            y = DrawDistrictHubBlock(y)

            DrawMonoLine(HUD_BASE_X, y, HUD_FRAME_TEXT, COLOR_DIM[1], COLOR_DIM[2], COLOR_DIM[3], HUD_TEXT_SCALE)
            y = y + HUD_LINE_HEIGHT

            if #hudLines == 0 then
                DrawMonoLine(HUD_BASE_X, y, '[SINYAL BEKLENIYOR — VERI AKISI YOK]', COLOR_DIM[1], COLOR_DIM[2], COLOR_DIM[3], HUD_TEXT_SCALE)
                y = y + HUD_LINE_HEIGHT
            else
                for i = 1, #hudLines do
                    local line = hudLines[i]
                    local r, g, b = COLOR_VALUE[1], COLOR_VALUE[2], COLOR_VALUE[3]
                    if line.danger then
                        r, g, b = COLOR_DANGER[1], COLOR_DANGER[2], COLOR_DANGER[3]
                    elseif line.header then
                        r, g, b = COLOR_HEADER[1], COLOR_HEADER[2], COLOR_HEADER[3]
                    end
                    DrawMonoLine(HUD_BASE_X, y, line.text, r, g, b, HUD_TEXT_SCALE)
                    y = y + HUD_LINE_HEIGHT
                end
            end

            DrawMonoLine(HUD_BASE_X, y, HUD_FRAME_TEXT, COLOR_DIM[1], COLOR_DIM[2], COLOR_DIM[3], HUD_TEXT_SCALE)
            Wait(0)
        else
            Wait(250)
        end
    end
end)

-- =====================================================================
-- ★★★ v18.0 KRİTİK: F10 TUŞ ATAMASI PAGE_UP'A MÜHÜRLENDİ ★★★
-- =====================================================================
AddEventHandler('onClientResourceStart', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end
    hudActive = false
    hudLines  = {}

    RegisterCommand('hud', function() ToggleHud() end, false)
    RegisterKeyMapping('hud', 'Taktik HUD ac/kapat', 'keyboard', Config.Hud and Config.Hud.ToggleKey or 'F6')

    RegisterCommand('comintpanel', function() ToggleHud() end, false)
    RegisterKeyMapping('comintpanel', 'COMINT Istihbarat Profili', 'keyboard', (Config.Comint and Config.Comint.ToggleKey) or 'K')

    -- ★ [SESSION 1 PURGE] Remote HOME key abolished. Interaction locked to
-- 1.8m ox_target zone at physical broker/counselor NPCs. The F10/HOME
-- key bypassed proximity and has been removed from the key mapping
-- registry. Physical-proximity enforcement is now the sole interaction
-- channel for asset management.
RegisterCommand('baronterminali', function()
    if lib and lib.notify then
        lib.notify({
            title       = 'SECURITY HANDSHAKE',
            description = 'Line disconnected — remote terminal discontinued. Use physical broker.',
            type        = 'error',
        })
    end
end, false)
-- RegisterKeyMapping(...) — REMOVED.

    RegisterCommand('notdefteri', function()
        OpenMatrixNotepad()
    end, false)
    RegisterKeyMapping('notdefteri', 'Operasyon Not Defterini Ac', 'keyboard', 'L')

    RegisterCommand('taktikturnike', function()
        ExecuteCommand(tostring((Config.Hospital and Config.Hospital.TreatmentCommand) or 'tedaviol'))
    end, false)
    RegisterKeyMapping('taktikturnike', 'Taktik Turnike / Yara Bakimi', 'keyboard', 'Y')

    RegisterKeyMapping('muhafizcagir', 'Hizli Tim Atama: Fiziksel Muhafiz Cagir', 'keyboard', 'G')
    RegisterKeyMapping('muhafizsalla', 'Hizli Tim Emri: Tum Takipcileri Serbest Birak', 'keyboard', 'H')
end)

-- =====================================================================
-- KATMAN 5 ULTIMATE [U3]: MEKANİK TUTUKLUK TESPİTİ & TAHLİYE
-- =====================================================================
local weaponJamActive = false
local weaponJamSlot    = nil

RegisterNetEvent('matrix:client:weaponJamStateChanged', function(slot, jammed)
    weaponJamActive = jammed and true or false
    weaponJamSlot    = jammed and slot or nil
end)

RegisterNetEvent('matrix:client:actionNotify', function(ok, message)
    if lib and lib.notify then
        lib.notify({
            title       = ok and '[ISLEM BASARILI]' or '[ISLEM BASARISIZ]',
            description = tostring(message or ''),
            type        = ok and 'success' or 'error',
            duration    = 6000
        })
    end
end)

RegisterNetEvent('matrix:client:darkchat:telemetry', function(payload)
    if type(payload) ~= 'table' then return end
    if lib and lib.notify then
        lib.notify({
            title       = ('[DARKCHAT // #%d]'):format(tonumber(payload.bot_id) or 0),
            description = tostring(payload.message or ''),
            type        = 'inform',
            duration    = 9000
        })
    end
end)

RegisterNetEvent('matrix:client:darkchat:telemetryResult', function(data, err)
    if lib and lib.notify then
        if not data then
            lib.notify({ title = '[DARKCHAT]', description = tostring(err or 'veri yok'), type = 'error' })
            return
        end
        local body = data.coords_masked
            and ('[NEED-TO-KNOW] Ajan #%d maskeli: %s | %s'):format(data.bot_id, tostring(data.coords_x), tostring(data.balance))
            or  ('Ajan #%d konum: %.1f,%.1f,%.1f | Bakiye: %.2f'):format(
                data.bot_id, data.coords_x, data.coords_y, data.coords_z, data.balance)
        lib.notify({ title = '[DARKCHAT TELEMETRI]', description = body, type = 'inform', duration = 8000 })
    end
end)

-- ★ mermi-delta tespit
local lastWeaponHash = nil
local lastAmmoInClip = nil
local WEAPON_UNARMED_HASH = GetHashKey('WEAPON_UNARMED')

CreateThread(function()
    while true do
        local ped = PlayerPedId()
        local weaponHash = GetSelectedPedWeapon(ped)

        if weaponHash and weaponHash ~= 0 and weaponHash ~= WEAPON_UNARMED_HASH then
            local ammo = GetAmmoInPedWeapon(ped, weaponHash)

            if weaponHash ~= lastWeaponHash then
                lastWeaponHash = weaponHash
                lastAmmoInClip = ammo
            elseif type(lastAmmoInClip) == 'number' and type(ammo) == 'number' and ammo < lastAmmoInClip then
                local shotsFired = lastAmmoInClip - ammo
                local ok, current = pcall(function() return exports['ox_inventory']:GetCurrentWeapon() end)
                if ok and type(current) == 'table' and current.weapon and current.slot then
                    for _ = 1, shotsFired do
                        TriggerServerEvent('matrix:server:reportWeaponShotFired', current.weapon, current.slot)
                    end
                end
                lastAmmoInClip = ammo
            elseif type(lastAmmoInClip) ~= 'number' or (type(ammo) == 'number' and ammo > lastAmmoInClip) then
                lastAmmoInClip = ammo
            end
        else
            lastWeaponHash = nil
            lastAmmoInClip = nil
        end

        Wait(weaponJamActive and 0 or 100)
    end
end)

CreateThread(function()
    while true do
        if weaponJamActive then
            DisablePlayerFiring(PlayerId(), true)
            DrawMonoLine(0.36, 0.90, '[MEKANIK: SILAH TUTUKLUK YAPTI]', COLOR_DANGER[1], COLOR_DANGER[2], COLOR_DANGER[3], 0.45)
            Wait(0)
        else
            Wait(250)
        end
    end
end)

local function BeginWeaponJamEvacuation()
    if not weaponJamActive or not weaponJamSlot then
        NotifyInvalidInput('Su an tutuklu bir silahiniz yok.')
        return
    end
    local slot = weaponJamSlot
    local completed = lib.progressCircle({
        duration     = WEAPON_EVAC_MS,
        position     = 'bottom',
        label        = 'Silah Kurma Kolu Cekiliyor / Sikisan Kovan Tahliye Ediliyor...',
        useWhileDead = false,
        canCancel    = true,
        disable      = { move = true, car = true, combat = true }
    })
    if completed then
        TriggerServerEvent('matrix:server:clearWeaponJam', slot)
    end
end

RegisterCommand('silahtahliye', function() BeginWeaponJamEvacuation() end, false)
RegisterKeyMapping('silahtahliye', 'Sikisan Silahi Tahliye Et', 'keyboard', 'X')

AddEventHandler('gameEventTriggered', function(eventName, args)
    if eventName ~= 'CEventNetworkEntityDamage' then return end
    local victim, attacker, weaponDamage, weaponHash = args[1], args[2], args[3], args[6]
    if victim ~= PlayerPedId() or not weaponDamage then return end
    local attackerServerId = nil
    if attacker and attacker ~= 0 and NetworkGetEntityIsNetworked(attacker) then
        if IsPedAPlayer(attacker) then
            attackerServerId = GetPlayerServerId(NetworkGetPlayerIndexFromPed(attacker))
        end
    end
    local weaponHashStr = weaponHash and tostring(weaponHash) or nil
    TriggerServerEvent('matrix:server:reportPlayerWounded', attackerServerId, weaponHashStr)
end)

exports('ReportPhoneCallState', function(active, isBurner)
    TriggerServerEvent('matrix:server:reportPhoneCallState', active, isBurner)
end)

local function OpenNamluDegistirAction()
    local ok, current = pcall(function() return exports['ox_inventory']:GetCurrentWeapon() end)
    if not ok or type(current) ~= 'table' or not current.slot then
        NotifyInvalidInput('Elinizde degistirilebilir bir silah yok.')
        return
    end
    ExecuteCommand(('namludegistir %d'):format(current.slot))
end

local function OpenWorkbenchRepairAction()
    local ok, current = pcall(function() return exports['ox_inventory']:GetCurrentWeapon() end)
    if not ok or type(current) ~= 'table' or not current.slot then
        NotifyInvalidInput('Elinizde tamir edilebilir bir silah yok.')
        return
    end
    TriggerServerEvent('matrix:server:workbench:repairWeapon', current.slot)
end

local function OpenTrapHouseDurumDialog()
    local input = lib.inputDialog('/traphousedurum - Trap House Sorgusu', {
        { type = 'number', label = 'Trap House ID', required = true, min = 1, max = 2147483646 }
    })
    if not input then return end
    local houseId = SanitizeNumericArg(input[1], 1, 2147483646)
    if not houseId then NotifyInvalidInput('Trap House ID gecersiz.'); return end
    ExecuteCommand(('traphousedurum %s'):format(houseId))
end

local function OpenTrapHouseWaypointDialog()
    local list = lib.callback.await('matrix:callback:getTrapHouseLocations', false)
    if type(list) ~= 'table' or #list == 0 then
        if lib and lib.notify then
            lib.notify({ title = '[TRAP HOUSE]', description = 'Henuz kayitli bir trap house yok.', type = 'inform' })
        end
        return
    end
    local options = {}
    for i = 1, #list do
        local entry = list[i]
        if type(entry) == 'table' and type(entry.id) == 'number' and type(entry.coords) == 'vector3' then
            options[#options + 1] = { value = tostring(entry.id), label = ('#%d — %s'):format(entry.id, entry.label or 'Trap House') }
        end
    end
    if #options == 0 then return end

    local input = lib.inputDialog('Trap House\'a Git (Waypoint)', {
        { type = 'select', label = 'Trap House', required = true, options = options }
    })
    if not input then return end
    local chosenId = tonumber(input[1])
    local target
    for i = 1, #list do
        if list[i].id == chosenId then target = list[i]; break end
    end
    if not target then return end
    SetNewWaypoint(target.coords.x, target.coords.y)
    if lib and lib.notify then
        lib.notify({ title = '[TRAP HOUSE]', description = ('Waypoint ayarlandi: #%d %s'):format(target.id, target.label or ''), type = 'inform' })
    end
end

local function OpenRutbeAtaDialog()
    local input = lib.inputDialog('/rutbeata - Hiyerarsi Rutbe Atamasi', {
        { type = 'number', label = 'Hedef Server ID', required = true, min = 1, max = 65535 },
        { type = 'select', label = 'Rutbe', required = true, options = {
            { value = 'Leader',            label = 'Leader (Baron)' },
            { value = 'Logistics_Officer', label = 'Logistics_Officer (Lojistik Subayi)' },
            { value = 'Chemist',           label = 'Chemist (Kimyager)' }
        } }
    })
    if not input then return end
    local targetSrc = SanitizeNumericArg(input[1], 1, 65535)
    if not targetSrc then NotifyInvalidInput('Hedef Server ID gecersiz.'); return end
    local rank = SanitizeRankArg(input[2])
    if not rank then NotifyInvalidInput('Rutbe secimi gecersiz.'); return end
    ExecuteCommand(('rutbeata %s %s'):format(targetSrc, rank))
end

local function OpenRotaCizDialog()
    local input = lib.inputDialog('/rotaciz - Multi-Waypoint Taktik Rota', {
        { type = 'number', label = 'Bot ID', required = true, min = 1, max = MAX_BOT_ID },
        { type = 'input', label = '1. Ugrak (opsiyonel)', required = false, max = MAX_WAYPOINT_LEN },
        { type = 'input', label = '2. Ugrak (opsiyonel)', required = false, max = MAX_WAYPOINT_LEN },
        { type = 'input', label = '3. Ugrak (opsiyonel)', required = false, max = MAX_WAYPOINT_LEN },
        { type = 'input', label = 'Final Hedef (ZORUNLU)', required = true, max = MAX_WAYPOINT_LEN },
        { type = 'input', label = 'Plaka (bos = foot)', required = false, max = MAX_PLATE_LEN },
        { type = 'select', label = 'Arac Tipi', required = true, options = BuildVehicleTypeOptions() }
    })
    if not input then return end
    local botId = SanitizeNumericArg(input[1], 1, MAX_BOT_ID)
    if not botId then NotifyInvalidInput('Bot ID gecersiz.'); return end
    local waypointArgs = {}
    for i = 2, 4 do
        local wp = SanitizeOptionalWaypointArg(input[i])
        if not wp then
            NotifyInvalidInput(('Uğrak #%d geçersiz.'):format(i - 1))
            return
        end
        waypointArgs[#waypointArgs + 1] = wp
    end
    local finalWp = SanitizeWaypointArg(input[5])
    if not finalWp then
        NotifyInvalidInput('Final Hedef geçersiz.')
        return
    end
    local plate = SanitizePlateArg(input[6])
    if plate == nil then NotifyInvalidInput('Plaka gecersiz.'); return end
    local vehicleType = SanitizeVehicleTypeArg(input[7])
    if not vehicleType then NotifyInvalidInput('Arac tipi gecersiz.'); return end
    ExecuteCommand(('rotaciz %s %s %s %s %s %s %s'):format(
        botId, waypointArgs[1], waypointArgs[2], waypointArgs[3], finalWp, plate, vehicleType))
end

local function OpenDoorReinforcementDialog()
    local input = lib.inputDialog('Kapı Sürgü Tahkimatı', {
        { type = 'number', label = 'Trap House ID', required = true, min = 1, max = 2147483646 },
        { type = 'select', label = 'Hedef Seviye', required = true, options = {
            { value = '1', label = 'Seviye 1 — Takviyeli Ahşap Sürgü' },
            { value = '2', label = 'Seviye 2 — Çelik Sürgü Barikatı' },
            { value = '3', label = 'Seviye 3 — Çift Katlı Çelik Barikat' }
        } }
    })
    if not input then return end
    local houseId = SanitizeNumericArg(input[1], 1, 2147483646)
    if not houseId then NotifyInvalidInput('Trap House ID gecersiz.'); return end
    local level = SanitizeNumericArg(input[2], 1, 3)
    if not level then NotifyInvalidInput('Seviye secimi gecersiz.'); return end
    TriggerServerEvent('matrix:server:doorReinforcement:install', tonumber(houseId), tonumber(level))
end

local function OpenMatrixDump()
    ExecuteCommand('matrixdump')
end

local OpenAssignInspectorDialog
local OpenBotInventoryOpsMenu
local OpenGiveItemToBotDialog
local OpenAmmoRunDialog

OpenAssignInspectorDialog = function(botId)
    local zoneOptions = {}
    for _, zone in ipairs(Config.Market and Config.Market.Zones or {}) do
        zoneOptions[#zoneOptions + 1] = { value = tostring(zone.id), label = zone.label or ('Bolge #' .. tostring(zone.id)) }
    end
    if #zoneOptions == 0 then NotifyInvalidInput('Tanimli bolge yok.'); return end

    local input = lib.inputDialog(('Denetleyici Ata — Bot #%d'):format(botId), {
        { type = 'select', label = 'Bolge', required = true, options = zoneOptions }
    })
    if not input then return end
    local zoneId = SanitizeNumericArg(input[1], 1, MAX_BOT_ID)
    if not zoneId then NotifyInvalidInput('Bolge secimi gecersiz.'); return end
    ExecuteCommand(('denetleyiciata %s %d'):format(zoneId, botId))
end

OpenGiveItemToBotDialog = function(botId)
    local input = lib.inputDialog(('Esya Teslim Et — Bot #%d'):format(botId), {
        { type = 'number', label = 'Kendi Envanter Slotunuz', required = true, min = 1, max = 999 },
        { type = 'number', label = 'Miktar', required = true, min = 1, max = 9999, default = 1 }
    })
    if not input then return end
    local slot = SanitizeNumericArg(input[1], 1, 999)
    if not slot then NotifyInvalidInput('Slot numarasi gecersiz.'); return end
    local count = SanitizeNumericArg(input[2], 1, 9999)
    if not count then NotifyInvalidInput('Miktar gecersiz.'); return end
    TriggerServerEvent('matrix:server:trapHouseInterior:giveItemToBot', botId, tonumber(slot), tonumber(count))
end

OpenBotInventoryOpsMenu = function(botId)
    local items = lib.callback.await('matrix:callback:getBotInventoryItems', false, botId)
    if type(items) ~= 'table' then items = {} end

    local options = {
        { title = '[ESYA TESLIM ET]', description = 'Kendi envanterinizden bota esya teslim edin.', icon = 'hand-holding',
          onSelect = function() OpenGiveItemToBotDialog(botId) end }
    }
    for i = 1, #items do
        local item = items[i]
        options[#options + 1] = {
            title       = ('[SLOT %d] %s'):format(item.slot or 0, item.label or item.name or '?'),
            description = ('Miktar: %d'):format(tonumber(item.count) or 1),
            disabled    = true
        }
    end
    lib.registerContext({
        id = 'matrix_bot_inventory_ops',
        title = ('MUHIMMAT / ENVANTER AMELIYATI — Bot #%d'):format(botId),
        menu = 'matrix_bot_actions',
        options = options
    })
    lib.showContext('matrix_bot_inventory_ops')
end

OpenAmmoRunDialog = function(prefilledTargetBotId)
    local input = lib.inputDialog('Muhimmat Sevkiyati (/muhimmatsevk)', {
        { type = 'number', label = 'Lojistik Bot ID (kaynak)', required = true, min = 1, max = MAX_BOT_ID },
        { type = 'number', label = 'Tetikci Bot ID (hedef)', required = true, min = 1, max = MAX_BOT_ID,
          default = prefilledTargetBotId and tonumber(prefilledTargetBotId) or nil }
    })
    if not input then return end
    local sourceBotId = SanitizeNumericArg(input[1], 1, MAX_BOT_ID)
    if not sourceBotId then NotifyInvalidInput('Lojistik Bot ID gecersiz.'); return end
    local targetBotId = SanitizeNumericArg(input[2], 1, MAX_BOT_ID)
    if not targetBotId then NotifyInvalidInput('Tetikci Bot ID gecersiz.'); return end
    ExecuteCommand(('muhimmatsevk %s %s'):format(sourceBotId, targetBotId))
end

OpenBotActionsMenu = function(botId, roleLabel)
    lib.registerContext({
        id = 'matrix_bot_actions',
        title = ('[BOT-ID: %d] AKSIYON MENUSU'):format(botId),
        menu = 'matrix_canli_kadro',
        options = {
            { title = '[OPERATIF TASFIYE]', description = 'Bu unsuru KALICI olarak siler.', icon = 'user-slash',
              onSelect = function()
                  local confirmed = lib.alertDialog({
                      header = 'Operatif Tasfiye Onayi',
                      content = ('Bot #%d KALICI olarak tasfiye edilecek.'):format(botId),
                      centered = true, cancel = true
                  })
                  if confirmed == 'confirm' then ExecuteCommand(('operatiftasfiye %d'):format(botId)) end
              end },
            { title = '[DENETLEYICI ATA]', description = 'Sigint/comint denetleyicisi atar.', icon = 'user-shield',
              onSelect = function() OpenAssignInspectorDialog(botId) end },
            { title = '[KADRO AMELIYAT]', description = 'Tibbi tedaviye alir.', icon = 'user-doctor',
              onSelect = function() ExecuteCommand(('kadroameliyat %d'):format(botId)) end },
            { title = '[MUHIMMAT / ENVANTER AMELIYATI]', description = 'Bot envanterini goruntule.', icon = 'boxes-stacked',
              onSelect = function() OpenBotInventoryOpsMenu(botId) end },
            { title = '[MUHIMMAT SEVKIYATI]', description = 'Lojistik sevkiyat baslat.', icon = 'truck-fast',
              onSelect = function() OpenAmmoRunDialog(botId) end }
        }
    })
    lib.showContext('matrix_bot_actions')
end

OpenCanliKadroMenu = function()
    local entries = lib.callback.await('matrix:callback:getRosterReport', false)
    if type(entries) ~= 'table' then entries = {} end

    local options = {}
    for i = 1, #entries do
        local entry = entries[i]
        if type(entry) == 'table' and type(entry.text) == 'string' then
            if entry.kind == 'bot' and type(entry.id) == 'number' then
                options[#options + 1] = {
                    title = entry.text,
                    icon = entry.mole_flagged and 'triangle-exclamation' or 'user',
                    onSelect = function() OpenBotActionsMenu(entry.id, entry.role) end
                }
            else
                options[#options + 1] = { title = entry.text, disabled = true }
            end
        end
    end
    if #options == 0 then options[1] = { title = '[KAYITLI UNSUR YOK]', disabled = true } end

    lib.registerContext({
        id = 'matrix_canli_kadro',
        title = '[CANLI KADRO]',
        menu = _currentBaronMenuId,
        options = options
    })
    lib.showContext('matrix_canli_kadro')
end

OpenMatrixNotepad = function()
    local options = {}
    for i = 1, #NotepadEntries do
        options[#options + 1] = { title = NotepadEntries[i].text, disabled = true }
    end
    if #options == 0 then options[1] = { title = '[DEFTER BOS]', disabled = true } end

    lib.registerContext({
        id = 'matrix_notepad',
        title = '[OPERASYON NOT DEFTERI]',
        menu = _currentBaronMenuId,
        options = options
    })
    lib.showContext('matrix_notepad')
end

-- =====================================================================
-- ★ PHASE6-STEP3 — HYDRAULIC PRESS CONTROL (inputDialog)
-- =====================================================================
OpenHydraulicPressDialog = function()
    local input = lib.inputDialog('Hidrolik Brick Presi (/presle)', {
        { type = 'number', label = 'Trap House ID', required = true, min = 1, max = 2147483646 },
        { type = 'select', label = 'Narkotik Tipi', required = true, options = HYDRAULIC_PRODUCT_OPTIONS },
        { type = 'number', label = ('Brick Sayisi (1 brick = %d poset)'):format(HYDRAULIC_BAGS_PER_BRICK),
          required = true, min = 1, max = 100, default = 1 }
    })
    if not input then return end
    local houseId = SanitizeNumericArg(input[1], 1, 2147483646)
    local productType = tostring(input[2] or '')
    local brickCount = SanitizeNumericArg(input[3], 1, 100)
    if not houseId then NotifyInvalidInput('Trap House ID gecersiz.'); return end
    if not (productType == 'meth_bag' or productType == 'coke_brick' or productType == 'masterpiece_gourmet_weed') then
        NotifyInvalidInput('Narkotik tipi gecersiz.'); return
    end
    if not brickCount then NotifyInvalidInput('Brick sayisi 1..100 araliginda olmali.'); return end
    ExecuteCommand(('presle %s %s %s'):format(houseId, productType, brickCount))
end

-- =====================================================================
-- ★ PHASE6-STEP3 — SERA BOTANY ENVIRONMENT OVERRIDE (inputDialog, floats)
-- =====================================================================
OpenBotanyEnvironmentDialog = function()
    local input = lib.inputDialog('Sera Botanik Ortam Override', {
        { type = 'number', label = 'Hedef pH Seviyesi (orn. 6.0)', required = true, min = 0.0, max = 14.0, step = 0.05 },
        { type = 'number', label = 'Hedef Fan Ruzgar Hizi (orn. 2.5)', required = true, min = 0.0, max = 10.0, step = 0.05 }
    })
    if not input then return end
    local ph  = SanitizeFloatArg(input[1], 0.0, 14.0)
    local fan = SanitizeFloatArg(input[2], 0.0, 10.0)
    if not ph then NotifyInvalidInput('pH degeri 0.0-14.0 araliginda olmali.'); return end
    if not fan then NotifyInvalidInput('Fan hizi 0.0-10.0 araliginda olmali.'); return end
    TriggerServerEvent('matrix:server:SetBotanyEnvironment', 1, ph, fan)
end

-- =====================================================================
-- KATEGORİ 2-A: Adli Arman Katmanları
-- =====================================================================
local function OpenForensicOpsMenu()
    lib.registerContext({
        id      = 'matrix_forensic_ops',
        title   = '[ADLİ ARMAN KATMANLARI]',
        menu    = _currentBaronMenuId,
        options = {
            { title = '[ASİTLE SİLAH TEMİZLE]', description = 'Eldeki silahın izini asitle kazır.', icon = 'flask',
              onSelect = function()
                  local ok, current = pcall(function() return exports['ox_inventory']:GetCurrentWeapon() end)
                  if not ok or type(current) ~= 'table' or not current.slot then
                      NotifyInvalidInput('Elinizde temizlenecek bir silah yok.')
                      return
                  end
                  ExecuteCommand(('silahtemizle %d'):format(current.slot))
              end },
            { title = '[OLAY YERİ DELİL KARARTMA]', description = 'Bölgedeki fiziksel delil izlerini karartır.', icon = 'broom',
              onSelect = function() ExecuteCommand('delilkarart') end },
            { title = '[KOVAN TOPLA — SAHNE TEMİZLİĞİ]', description = 'Kovanları adli kayıttan sil.', icon = 'box',
              onSelect = function()
                  local input = lib.inputDialog('Kovan Toplama (/kovantopla)', {
                      { type = 'number', label = 'Bot ID', required = true, min = 1, max = MAX_BOT_ID },
                      { type = 'input', label = 'Koordinat "x,y,z"', required = true, max = MAX_WAYPOINT_LEN }
                  })
                  if not input then return end
                  local botId = SanitizeNumericArg(input[1], 1, MAX_BOT_ID)
                  local wp    = SanitizeWaypointArg(input[2])
                  if not botId or not wp then NotifyInvalidInput('Gecersiz parametre.'); return end
                  ExecuteCommand(('kovantopla %s %s'):format(botId, wp:gsub(',', ' ')))
              end },
            { title = '[MOBESE AĞINA SIZ]', description = 'Bir bölgenin mobese geçmişini siler.', icon = 'video-slash',
              onSelect = function()
                  local input = lib.inputDialog('Mobese Hack (/mobesehackle)', {
                      { type = 'number', label = 'Bölge (Zone) ID', required = true, min = 1, max = MAX_BOT_ID }
                  })
                  if not input then return end
                  local zoneId = SanitizeNumericArg(input[1], 1, MAX_BOT_ID)
                  if not zoneId then NotifyInvalidInput('Gecersiz bölge.'); return end
                  ExecuteCommand(('mobesehackle %s'):format(zoneId))
              end },
            { title = '[ROUTER KUTUSUNDAN KAMERA VERİSİ TEMİZLE]', description = 'Son 30dk mobese izini kazır.', icon = 'network-wired',
              onSelect = function() ExecuteCommand('kameralogutemizle') end },
            { title = '[DARKCHAT HAT SABOTAJI]', description = 'Kendi açık hattınızdaki mesajları atomik imha eder.', icon = 'phone-slash',
              onSelect = function() ExecuteCommand('telefonuyoket') end },
            { title = '[KANIT YÜKLE — FRAME-UP]', description = 'Yağmalanmış silahı davaya hard-evidence bağlar.', icon = 'gavel',
              onSelect = function()
                  local input = lib.inputDialog('Kanıt Yükleme (/kanityukle)', {
                      { type = 'number', label = 'Şüpheli Server ID', required = true, min = 1, max = 65535 },
                      { type = 'number', label = 'Silah Slotu', required = true, min = 1, max = 999 }
                  })
                  if not input then return end
                  local sId  = SanitizeNumericArg(input[1], 1, 65535)
                  local slot = SanitizeNumericArg(input[2], 1, 999)
                  if not sId or not slot then NotifyInvalidInput('Gecersiz parametre.'); return end
                  ExecuteCommand(('kanityukle %s %s'):format(sId, slot))
              end }
        }
    })
    lib.showContext('matrix_forensic_ops')
end

-- =====================================================================
-- KATEGORİ 2-B: Buluşma Noktası Rapor Defteri + Clipboard
-- =====================================================================
local function CopyToClipboard(text)
    text = tostring(text or '')
    if text == '' then return false end
    local sent = pcall(function()
        SendNUIMessage({ type = 'copyToClipboard', text = text })
    end)
    TriggerEvent('chat:addMessage', {
        color = { 110, 255, 140 }, multiline = true,
        args = { '[NOT DEFTERİ — KOPYALANDI]', text }
    })
    return sent
end

local liveWaypointCoords = nil
CreateThread(function()
    while true do
        Wait(500)
        local blip = GetFirstBlipInfoId(8)
        if blip and blip ~= 0 then
            local ok, coords = pcall(GetBlipInfoIdCoord, blip)
            if ok and coords then liveWaypointCoords = coords end
        else
            liveWaypointCoords = nil
        end
    end
end)

local function OpenRendezvousNotepad()
    local options = {}
    if liveWaypointCoords then
        local coordStr = ('%.2f,%.2f,%.2f'):format(
            liveWaypointCoords.x, liveWaypointCoords.y, liveWaypointCoords.z)
        options[#options + 1] = {
            title       = '[CANLI WAYPOINT] Haritadaki kırmızı işaretçi',
            description = ('Tıkla → panoya kopyalanır: %s'):format(coordStr),
            icon        = 'map-pin',
            onSelect    = function()
                CopyToClipboard(coordStr)
                if lib and lib.notify then
                    lib.notify({ title = '[KOPYALANDI]', description = 'Buluşma koordinatı panonuza kopyalandı.', type = 'success' })
                end
            end
        }
    else
        options[#options + 1] = {
            title = '[WAYPOINT BEKLENIYOR]',
            description = 'Haritaya bir waypoint yerleştirin.',
            disabled = true
        }
    end
    for i = 1, #NotepadEntries do
        local entryText = NotepadEntries[i].text
        local coordMatch = entryText:match('(%-?%d+%.?%d*,%-?%d+%.?%d*,%-?%d+%.?%d*)')
        options[#options + 1] = {
            title       = entryText,
            description = coordMatch and ('Tıkla → panoya kopyalanır: %s'):format(coordMatch) or nil,
            icon        = 'bookmark',
            disabled    = not coordMatch,
            onSelect    = coordMatch and function()
                CopyToClipboard(coordMatch)
                if lib and lib.notify then
                    lib.notify({ title = '[KOPYALANDI]', description = 'Buluşma koordinatı panonuza kopyalandı.', type = 'success' })
                end
            end or nil
        }
    end
    lib.registerContext({
        id      = 'matrix_rendezvous_notepad',
        title   = '[BULUŞMA NOKTASI RAPOR DEFTERİ]',
        menu    = _currentBaronMenuId,
        options = options
    })
    lib.showContext('matrix_rendezvous_notepad')
end

local CommandInjectRoute
local CommandVettingRadar
local CommandLedgerBalance
local CommandPanicWipe

local _baronMenuCounter = 0

OpenBaronTerminaliMenu = function()
    pcall(function()
        if lib.hideContext then lib.hideContext() end
    end)

    _baronMenuCounter = _baronMenuCounter + 1
    local menuId = ('matrix_baron_terminali_%d'):format(_baronMenuCounter)
    _currentBaronMenuId = menuId

    lib.registerContext({
        id    = menuId,
        title = '[BARON TERMINALI]',
        options = {
            { title = '[CANLI KADRO]', description = 'Kayitli unsurlari listele.', icon = 'users', onSelect = function() OpenCanliKadroMenu() end },
            { title = '[TRAP HOUSE SORGUSU]', description = 'Trap house durumunu sorgula.', icon = 'house-lock', onSelect = function() OpenTrapHouseDurumDialog() end },
            { title = '[TRAP HOUSE\'A GIT]', description = 'GPS waypoint ayarla.', icon = 'location-dot', onSelect = function() OpenTrapHouseWaypointDialog() end },
            { title = '[ROTA CIZ]', description = 'Multi-waypoint taktik rota.', icon = 'route', onSelect = function() OpenRotaCizDialog() end },
            { title = '[KAPI SURGU TAHKIMATI]', description = 'Kapıyı tahkim et.', icon = 'shield-halved', onSelect = function() OpenDoorReinforcementDialog() end },
            { title = '[RUTBE ATAMASI]', description = 'Hiyerarsi rutbesi ata.', icon = 'ranking-star', onSelect = function() OpenRutbeAtaDialog() end },
            { title = '[NAMLU DEGISTIR]', description = 'Silahin namlusunu degistir.', icon = 'gun', onSelect = function() OpenNamluDegistirAction() end },
            { title = '[TEZGAHTA TAMIR]', description = 'Is tezgahinda tamir et.', icon = 'screwdriver-wrench', onSelect = function() OpenWorkbenchRepairAction() end },
            { title = '[MUHIMMAT SEVKIYATI]', description = 'Muhimmat sevkiyat baslat.', icon = 'truck-fast', onSelect = function() OpenAmmoRunDialog() end },
            { title = '[FIZIKSEL MUHAFIZ CAGIR]', description = 'Muhafiz/kurye takipcisi cagir.', icon = 'user-plus', onSelect = function() ExecuteCommand('muhafizcagir') end },
            { title = '[TIM EMRI: SERBEST BIRAK]', description = 'Tum takipcileri serbest birak.', icon = 'user-xmark', onSelect = function() ExecuteCommand('muhafizsalla') end },
            { title = '[ADLİ ARMAN KATMANLARI]', description = 'Asit/delilkarart/mobese/frame-up.', icon = 'flask', onSelect = function() OpenForensicOpsMenu() end },
            { title = '[BULUŞMA RAPOR DEFTERİ]', description = 'Canlı waypoint + kayıtlı notlar.', icon = 'map-pin', onSelect = function() OpenRendezvousNotepad() end },
            { title = '[OPERASYON NOT DEFTERI]', description = 'Otomatik kayitli notlar.', icon = 'book', onSelect = function() OpenMatrixNotepad() end },
            { title = '[MATRIX DUMP]', description = 'Tani dokumu (debug).', icon = 'bug', onSelect = function() OpenMatrixDump() end },
            { title = '[★ OTONOM ROTA ENJEKSIYONU]', description = 'Panodaki vector3 koordinatını seçili botun rotasına enjekte eder.', icon = 'route', onSelect = function() CommandInjectRoute() end },
            { title = '[★ VETTING INSPECTION RADAR]', description = '8.0m içindeki en yakın pedin biyometrik dosyasını getirir.', icon = 'crosshairs', onSelect = function() CommandVettingRadar() end },
            { title = '[★ MALİ DEFTER & MASS CAP]', description = 'Escrow geri sayımları + 150kg trap house doluluk oranı.', icon = 'scale-balanced', onSelect = function() CommandLedgerBalance() end },
            { title = '[★ PANİK BUTONU (REMOTE WIPE)]', description = 'cyber_leak >0.80 ise burner_phone tüketir, 3 bio-log siler.', icon = 'triangle-exclamation', onSelect = function() CommandPanicWipe() end },
            -- ★ PHASE6-STEP3 — new interactive buttons
            { title = '[★ HİDROLİK BRİCK PRESİ]', description = ('Manuel girdi: trap house + narkotik + brick adedi (%d poset/brick).'):format(HYDRAULIC_BAGS_PER_BRICK), icon = 'weight-hanging', onSelect = function() OpenHydraulicPressDialog() end },
            { title = '[★ SERA BOTANY ENVIRONMENT OVERRIDE]', description = 'Manuel girdi: hedef pH ve fan rüzgar hızı (ondalıklı).', icon = 'seedling', onSelect = function() OpenBotanyEnvironmentDialog() end },
        }
    })

    lib.showContext(menuId)

    if _baronMenuCounter >= 100 then
        _baronMenuCounter = 0
    end
end

RegisterNetEvent('matrix:client:rendezvousAssigned', function(payload)
    if type(payload) ~= 'table' or type(payload.coords) ~= 'vector3' then return end
    SetNewWaypoint(payload.coords.x, payload.coords.y)
    AddNotepadEntry(('[BULUSMA #%s] %s — Waypoint ayarlandi (%.2f, %.2f, %.2f).'):format(
        tostring(payload.handoff_id or '?'), tostring(payload.label or 'Karaborsa Teslimati'),
        payload.coords.x, payload.coords.y, payload.coords.z))
    if lib and lib.notify then
        lib.notify({ title = '[RENDEZVOUS]', description = 'Bulusma noktasi ayarlandi.', type = 'inform' })
    end
end)

RegisterNetEvent('matrix:client:darkchat:passphraseResult', function(ok, reason, trapHouseId)
    if lib and lib.notify then
        lib.notify({
            title       = ok and '[SEC-7 ONAY]' or '[SEC-7 RED]',
            description = ok and 'Parola kabul edildi.' or ('Parola reddedildi: ' .. tostring(reason)),
            type        = ok and 'success' or 'error',
            duration    = 5000
        })
    end
end)

RegisterNetEvent('matrix:client:fleetBulletin', function(text, danger)
    if type(text) ~= 'string' then return end
    if not hudActive then return end
    hudLines[#hudLines + 1] = { text = text, header = false, danger = danger and true or false }
    if #hudLines > MAX_HUD_LINES then table.remove(hudLines, 1) end
end)

local function FormatFleetBulletin(state)
    if type(state) ~= 'table' or type(state.kind) ~= 'string' then return nil, false end
    if state.kind == 'dispatching' then
        return '[FİLO: ARAC SIFNI — NOKTAYI SAVUNARAK İNTİKAL EDİLİYOR]', false
    elseif state.kind == 'depositing' then
        return '[FİLO: ENVANTER DEPOYA AKTARILIYOR — KÜTLE TRANSFERİ]', false
    elseif state.kind == 'panic' then
        return '[FİLO: DURUM — ACİL TAHLİYE / SANA DOĞRU KAÇIYOR]', true
    end
    return nil, false
end

exports('FormatFleetBulletin', function(state) return FormatFleetBulletin(state) end)

-- =====================================================================
-- ★ PHASE 5 / REF-2: MONOKROM INTERACTIVE COMMAND HUD
-- =====================================================================
local VETTING_RADIUS        = 8.0
local COERCION_PROXIMITY    = 3.0
local PANIC_LEAK_THRESHOLD  = 0.80
local STASH_MASS_CAP_KG     = 150.0

local function HudNotify(msg, tag)
    TriggerEvent('chat:addMessage', { args = { tag or '[MONOKROM]', msg } })
end

local function GetClosestPedInRadius(radius)
    local myPed = PlayerPedId()
    local myCoords = GetEntityCoords(myPed)
    local best, bestDist = nil, radius + 0.001
    local pool = GetGamePool('CPed')
    for i = 1, #pool do
        local ped = pool[i]
        if ped ~= myPed and not IsPedAPlayer(ped) and DoesEntityExist(ped) then
            local c = GetEntityCoords(ped)
            local d = #(c - myCoords)
            if d < bestDist then
                best, bestDist = ped, d
            end
        end
    end
    return best, bestDist
end

local function ParseClipboardVector3(raw)
    if type(raw) ~= 'string' then return nil end
    local x, y, z = raw:match('^%s*(-?%d+%.?%d*)%s+(-?%d+%.?%d*)%s+(-?%d+%.?%d*)%s*$')
    if not x or not y or not z then return nil end
    return vector3(tonumber(x), tonumber(y), tonumber(z))
end

local function GetClipboardSync()
    if type(lib) == 'table' and type(lib.getClipboard) == 'function' then
        local ok, res = pcall(lib.getClipboard)
        if ok and type(res) == 'string' then return res end
    end
    return ''
end

CommandInjectRoute = function()
    local raw = GetClipboardSync()
    local vec = ParseClipboardVector3(raw)
    if not vec then
        HudNotify('Pano formatı geçersiz. "/isaretkopyala" ile kopyalanmış bir vector3 bekleniyor.', '[ROTA]')
        return
    end
    TriggerServerEvent('matrix:server:injectBotRoute', vec.x, vec.y, vec.z)
    HudNotify(('Rota enjekte edildi → (%.2f, %.2f, %.2f)'):format(vec.x, vec.y, vec.z), '[ROTA]')
end

CommandVettingRadar = function()
    local ped, dist = GetClosestPedInRadius(VETTING_RADIUS)
    if not ped then
        HudNotify(('%.1fm yarıçapında hedef yok.'):format(VETTING_RADIUS), '[VETTING]')
        return
    end
    local netId = NetworkGetNetworkIdFromEntity(ped)
    TriggerServerEvent('matrix:server:requestVettingDossier', netId)
    local myCoords = GetEntityCoords(PlayerPedId())
    local targetCoords = GetEntityCoords(ped)
    local mid = (myCoords + targetCoords) * 0.5
    DrawMarker(28, mid.x, mid.y, mid.z, 0,0,0, 0,0,0,
        0.35, 0.35, 0.35, 0, 255, 180, 120, false, false, 2, false, nil, nil, false)
    HudNotify(('Vetting taraması: ped=%d mesafe=%.2fm'):format(netId, dist), '[VETTING]')
end

-- =====================================================================
-- ★ PHASE6-STEP2 — CommandLedgerBalance: Mali Defter & 150kg Mass Cap
-- Trap house escrow geri sayımlarını (server-authoritative callback) ve
-- o trap house'un ortak deposundaki (ox_inventory stash) DOLU kütleyi
-- 150.0 kg katı limitine göre okunur bir ledger olarak gösterir.
-- =====================================================================
CommandLedgerBalance = function()
    local input = lib.inputDialog('/malidefter - Escrow ve Stash Mali Defteri', {
        { type = 'number', label = 'Trap House ID', required = true, min = 1, max = 2147483646 }
    })
    if not input then return end
    local houseId = SanitizeNumericArg(input[1], 1, 2147483646)
    if not houseId then NotifyInvalidInput('Trap House ID gecersiz.'); return end
    houseId = tonumber(houseId)

    -- Server-authoritative: 24 saatlik escrow işlemlerinin geri sayımı
    -- yalnızca sunucudan (matrix_bureau_escrow benzeri kalıcı bir tablodan)
    -- okunabilir; istemci hiçbir zaman kendi sayacını üretmez.
    local ledger = lib.callback.await('matrix:callback:getEscrowLedger', false, houseId)
    if type(ledger) ~= 'table' then ledger = {} end

    local escrowLines = {}
    for i = 1, #ledger do
        local entry = ledger[i]
        if type(entry) == 'table' then
            local remainingSeconds = tonumber(entry.remaining_seconds) or 0
            if remainingSeconds < 0 then remainingSeconds = 0 end
            local hh = math.floor(remainingSeconds / 3600)
            local mm = math.floor((remainingSeconds % 3600) / 60)
            escrowLines[#escrowLines + 1] = ('#%d %.2f$ / %02dh%02dm'):format(
                tonumber(entry.id) or 0, tonumber(entry.amount) or 0.0, hh, mm)
        end
    end
    local escrowSummary = (#escrowLines > 0) and table.concat(escrowLines, '  |  ') or 'Aktif escrow islemi yok.'

    -- Trap house'un ortak deposu (matrix_trap_stash_<id>) — DOLU kütle
    -- ox_inventory export'undan doğrudan okunur; server push'u (hydraulic
    -- telemetry) her zaman 2sn'ye kadar bayat olabileceğinden burada
    -- okunabilir bir ledger için otoriter/anlık kaynak tercih edilir.
    local stashId = ('matrix_trap_stash_%d'):format(houseId)
    local ok, stashItems = pcall(function()
        return exports['ox_inventory']:GetInventoryItems(stashId)
    end)

    local filledKg = 0.0
    if ok and type(stashItems) == 'table' then
        for _, item in pairs(stashItems) do
            if type(item) == 'table' then
                local weightGrams = tonumber(item.weight) or 0.0
                local count       = tonumber(item.count) or 0
                filledKg = filledKg + ((weightGrams * count) / 1000.0)
            end
        end
    else
        -- ox_inventory export'u erisilemezse (stash henuz yuklenmemis/farkli
        -- bir kaynak) en son bilinen hidrolik telemetri degerine duser --
        -- bu bir HATA degil, salt-okunur bir yedek kaynaktir.
        filledKg = tonumber(hydraulicTelemetry.stash_filled_kg) or 0.0
    end
    if filledKg < 0.0 then filledKg = 0.0 end

    local ratio = filledKg / HYDRAULIC_STASH_CAP_KG
    if ratio < 0.0 then ratio = 0.0 end
    if ratio > 1.0 then ratio = 1.0 end

    lib.inputDialog(('Mali Defter — Trap House #%d'):format(houseId), {
        { type = 'input', label = 'Escrow Geri Sayimlari (24s Pencere)', disabled = true, default = escrowSummary },
        { type = 'input', label = 'Stash Doluluk Orani', disabled = true,
          default = ('%.2f / %.1f kg  (%%%.1f)'):format(filledKg, HYDRAULIC_STASH_CAP_KG, ratio * 100.0) }
    })
end

-- =====================================================================
-- ★ PHASE6-STEP2 — CommandPanicWipe: Uzaktan İmha Panik Butonu
-- cyber_leak_intensity / CyberLeakMaxIntensity orani PANIC_LEAK_THRESHOLD
-- (0.80) esigini GECTIYSE: 1x 'burner_phone' tuketir, saha sevkiyatlarini
-- durdurur ve 3 rastgele biyometrik adli kayit satirinin sunucu tarafinda
-- KALICI olarak imhasini talep eder. RNG istemcide YOKTUR — rastgele
-- secim (3 satir) MEVCUT sunucu tarafinda, deterministik-disi tek nokta
-- olarak kalir; istemci sadece "3" adedini iletir.
-- =====================================================================
CommandPanicWipe = function()
    local heatRatio = lib.callback.await('matrix:callback:getNearestCyberLeakRatio', false)
    heatRatio = tonumber(heatRatio) or 0.0
    if heatRatio ~= heatRatio then heatRatio = 0.0 end -- NaN korumasi

    if heatRatio <= PANIC_LEAK_THRESHOLD then
        HudNotify(('Siber sizinti orani %%%.0f — panik esigi %%%.0f. Islem gerekmiyor.'):format(
            heatRatio * 100.0, PANIC_LEAK_THRESHOLD * 100.0), '[PANİK]')
        return
    end

    local searchOk, burnerCount = pcall(function()
        return exports['ox_inventory']:Search('count', 'burner_phone')
    end)
    burnerCount = (searchOk and tonumber(burnerCount)) or 0
    if burnerCount < 1 then
        NotifyInvalidInput('Panik butonu icin envanterde en az 1 adet [burner_phone] gerekli.')
        return
    end

    local confirmed = lib.alertDialog({
        header   = 'PANİK BUTONU — UZAKTAN İMHA',
        content  = ('Siber sizinti orani %%%.0f. 1x [burner_phone] tuketilecek, saha sevkiyatlari durdurulacak ve 3 biyometrik adli kayit KALICI olarak imha edilecek. Onayliyor musunuz?'):format(heatRatio * 100.0),
        centered = true,
        cancel   = true
    })
    if confirmed ~= 'confirm' then return end

    local removed = false
    local removeOk = pcall(function()
        removed = exports['ox_inventory']:RemoveItem('burner_phone', 1)
    end)
    if not removeOk or not removed then
        NotifyInvalidInput('burner_phone tuketilemedi — islem iptal edildi.')
        return
    end

    TriggerServerEvent('matrix:server:abortFieldDispatches')
    TriggerServerEvent('matrix:server:remoteWipeBiometrics', 3)
    HudNotify('★ PANİK BUTONU TETİKLENDİ — saha sevkiyatlari durduruldu, 3 biyometrik adli kayit imha talebi gonderildi.', '[PANİK]')
end

-- =====================================================================
-- ★ GEÇİCİ TEST — Sunucudan gelen stash açma sinyalini işle
-- TEST SONRASI BU BLOĞU SİL!
-- =====================================================================
RegisterNetEvent('matrix:client:openStashForPlayer', function(stashId)
    local ok, err = pcall(function()
        exports.ox_inventory:openInventory('stash', stashId)
    end)
    if not ok then
        TriggerEvent('chat:addMessage', {
            args = { '[STASH]', ('Acilamadi (%s): %s'):format(tostring(stashId), tostring(err)) }
        })
    end
end)