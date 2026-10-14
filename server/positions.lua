-- =====================================================================
-- MATRIX POSITIONS — FAZ 2.5
-- 7 slot × 5 tip × LOS + Reflex
-- =====================================================================
-- FELSEFE:
--   • Sayısal bonus YOK (arcade yasak)
--   • LOS + görüş açısı + trade-off (simülasyon)
--   • Ateş altında yedek slota geç (Arma 3 reflex özü)
--   • 0 RNG — tüm koordinatlar deterministik
--   • Server FPS dostu: O(1) state check, tick seyreltme
-- =====================================================================

Matrix.Positions = Matrix.Positions or {}

local SLOT_TYPES = {
    [1] = { type = 'gate',   los_range = 25.0,  fov = 90.0,  pitch_min = -15.0, pitch_max = 30.0  },
    [2] = { type = 'gate',   los_range = 25.0,  fov = 90.0,  pitch_min = -15.0, pitch_max = 30.0  },
    [3] = { type = 'roof',   los_range = 200.0, fov = 200.0, pitch_min = -60.0, pitch_max = 15.0  },
    [4] = { type = 'roof',   los_range = 200.0, fov = 200.0, pitch_min = -60.0, pitch_max = 15.0  },
    [5] = { type = 'hub',    los_range = 40.0,  fov = 120.0, pitch_min = -20.0, pitch_max = 25.0  },
    [6] = { type = 'inner',  los_range = 12.0,  fov = 60.0,  pitch_min = -10.0, pitch_max = 20.0  },
    [7] = { type = 'escape', los_range = 15.0,  fov = 100.0, pitch_min = -10.0, pitch_max = 30.0  },
}

local REFLEX_TICK_MS       = 1000
local UNDER_FIRE_WINDOW_MS = 3000
local REFLEX_BACKOFF_MS    = 10000

-- =====================================================================
-- YARDIMCILAR
-- =====================================================================
local function ComputeSlotCoords(trapHouseId, slotIndex, centerX, centerY, centerZ)
    local def = SLOT_TYPES[slotIndex]
    if not def then return nil end

    local baseAngle = (slotIndex * 51.4) % 360

    local radius, angleOffset
    if def.type == 'gate' then
        radius, angleOffset = 8.0, 0.0
    elseif def.type == 'roof' then
        radius, angleOffset = 35.0, 45.0
    elseif def.type == 'hub' then
        radius, angleOffset = 15.0, 0.0
    elseif def.type == 'inner' then
        radius, angleOffset = 2.0, 0.0
    elseif def.type == 'escape' then
        radius, angleOffset = 20.0, 0.0
    end

    local finalAngle = math.rad(baseAngle + angleOffset)
    local x = centerX + math.cos(finalAngle) * radius
    local y = centerY + math.sin(finalAngle) * radius
    local z = centerZ

    local headingDeg = math.deg(math.atan(y - centerY, x - centerX)) + 90.0
    headingDeg = (headingDeg + 360) % 360

    return x, y, z, headingDeg
end

local function ComputeBackupCoords(primaryX, primaryY, primaryZ, primaryHeading)
    local perpAngle = math.rad(primaryHeading + 90.0)
    local bx = primaryX + math.cos(perpAngle) * 3.0
    local by = primaryY + math.sin(perpAngle) * 3.0
    return bx, by, primaryZ, primaryHeading
end

local function IsTargetInLOS(slot, targetX, targetY, targetZ)
    if not slot then return false, nil end
    -- ★ [FIX] Type guard — client-bridge'den string/nil gelebilir
    targetX = tonumber(targetX)
    targetY = tonumber(targetY)
    targetZ = tonumber(targetZ)
    if not (targetX and targetY and targetZ) then return false, nil end

    if slot.using_backup == 1 then
        if not slot.backup_x then return false, nil end
        slot._active_x = slot.backup_x
        slot._active_y = slot.backup_y
        slot._active_z = slot.backup_z
        slot._active_h = slot.backup_heading or slot.heading
    else
        slot._active_x = slot.coord_x
        slot._active_y = slot.coord_y
        slot._active_z = slot.coord_z
        slot._active_h = slot.heading
    end

    local dx = targetX - slot._active_x
    local dy = targetY - slot._active_y
    local dz = targetZ - slot._active_z
    local dist = math.sqrt(dx*dx + dy*dy + dz*dz)

    if dist > slot.los_range_m then return false, nil end

    local targetAngle = math.deg(math.atan(dy, dx))
    local slotHeading = slot._active_h or 0.0
    local slotAtanAngle = 90.0 - slotHeading
    local diff = targetAngle - slotAtanAngle
    while diff > 180.0  do diff = diff - 360.0 end
    while diff < -180.0 do diff = diff + 360.0 end

    if math.abs(diff) > (slot.los_fov_deg / 2.0) then return false, nil end

    local horizontalDist = math.sqrt(dx*dx + dy*dy)
    local pitch = math.deg(math.atan(dz, horizontalDist))
    if pitch < slot.los_pitch_min or pitch > slot.los_pitch_max then
        return false, nil
    end

    return true, dist
end

-- =====================================================================
-- YÜKLEME
-- =====================================================================
Matrix.Positions.Registry = Matrix.Positions.Registry or {}

function Matrix.Positions.LoadPositions()
    local rows = MySQL.query.await('SELECT * FROM matrix_positions WHERE side = ?', { 'defense' }) or {}
    Matrix.Positions.Registry = {}

    for _, row in ipairs(rows) do
        local tid = tonumber(row.trap_house_id)
        local idx = tonumber(row.slot_index)
        if tid and idx then
            Matrix.Positions.Registry[tid] = Matrix.Positions.Registry[tid] or {}
            Matrix.Positions.Registry[tid][idx] = {
                id               = tonumber(row.id),
                trap_house_id    = tid,
                slot_index       = idx,
                slot_type        = row.slot_type,
                side             = row.side,
                coord_x          = tonumber(row.coord_x) or 0.0,
                coord_y          = tonumber(row.coord_y) or 0.0,
                coord_z          = tonumber(row.coord_z) or 0.0,
                heading          = tonumber(row.heading) or 0.0,
                backup_x         = row.backup_x and tonumber(row.backup_x),
                backup_y         = row.backup_y and tonumber(row.backup_y),
                backup_z         = row.backup_z and tonumber(row.backup_z),
                backup_heading   = row.backup_heading and tonumber(row.backup_heading),
                los_range_m      = tonumber(row.los_range_m) or 30.0,
                los_fov_deg      = tonumber(row.los_fov_deg) or 120.0,
                los_pitch_min    = tonumber(row.los_pitch_min) or -30.0,
                los_pitch_max    = tonumber(row.los_pitch_max) or 45.0,
                assigned_bot_id  = row.assigned_bot_id and tonumber(row.assigned_bot_id),
                assigned_citizenid = row.assigned_citizenid,
                assigned_at      = row.assigned_at,
                under_fire       = tonumber(row.under_fire) or 0,
                last_fire_at     = row.last_fire_at,
                using_backup     = tonumber(row.using_backup) or 0,
            }
        end
    end

    local cnt = 0
    for _ in pairs(Matrix.Positions.Registry) do cnt = cnt + 1 end
    Matrix.Log('POSITIONS', '%d trap house için slot konfigürasyonu yüklendi.', cnt)
end

CreateThread(function()
    Wait(1500)
    local ok, err = pcall(Matrix.Positions.LoadPositions)
    if not ok then
        Matrix.Log('POSITIONS', '[HATA] LoadPositions: %s', tostring(err))
    end
end)

-- =====================================================================
-- SEED
-- =====================================================================
function Matrix.Positions.SeedDefaults(trapHouseId)
    trapHouseId = tonumber(trapHouseId)
    if not trapHouseId then return false, 'bad_id' end

    local house = Matrix.TrapHouses and Matrix.TrapHouses[trapHouseId]
    if not house or not house.coords then return false, 'no_trap_house' end

    local cx, cy, cz = house.coords.x, house.coords.y, house.coords.z
    local inserts = {}

    for idx = 1, 7 do
        local def = SLOT_TYPES[idx]
        local x, y, z, heading = ComputeSlotCoords(trapHouseId, idx, cx, cy, cz)
        local bx, by, bz, bheading = nil, nil, nil, nil

        if idx < 7 then
            bx, by, bz, bheading = ComputeBackupCoords(x, y, z, heading)
        end

        inserts[#inserts + 1] = {
            query = [[
                INSERT INTO matrix_positions
                    (trap_house_id, slot_index, slot_type, side,
                     coord_x, coord_y, coord_z, heading,
                     backup_x, backup_y, backup_z, backup_heading,
                     los_range_m, los_fov_deg, los_pitch_min, los_pitch_max)
                VALUES (?, ?, ?, 'defense', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON DUPLICATE KEY UPDATE
                    coord_x = VALUES(coord_x),
                    coord_y = VALUES(coord_y),
                    coord_z = VALUES(coord_z),
                    heading = VALUES(heading),
                    backup_x = VALUES(backup_x),
                    backup_y = VALUES(backup_y),
                    backup_z = VALUES(backup_z),
                    backup_heading = VALUES(backup_heading)
            ]],
            values = {
                trapHouseId, idx, def.type,
                x, y, z, heading,
                bx, by, bz, bheading,
                def.los_range, def.fov, def.pitch_min, def.pitch_max
            }
        }
    end

    local ok, err = pcall(function()
        return MySQL.transaction.await(inserts)
    end)
    if not ok then
        Matrix.Log('POSITIONS', '[HATA] SeedDefaults transaction: %s', tostring(err))
        return false, 'db_error'
    end

    pcall(Matrix.Positions.LoadPositions)

    Matrix.Log('POSITIONS', '[SEED] Trap #%d için 7 slot oluşturuldu.', trapHouseId)
    return true
end

-- =====================================================================
-- ATAMA
-- =====================================================================
function Matrix.Positions.AssignBot(trapHouseId, slotIndex, botId, citizenid)
    trapHouseId = tonumber(trapHouseId)
    slotIndex = tonumber(slotIndex)
    if not trapHouseId or not slotIndex then return false, 'bad_args' end
    if slotIndex < 1 or slotIndex > 7 then return false, 'bad_slot' end

    local trapReg = Matrix.Positions.Registry[trapHouseId]
    if not trapReg then return false, 'no_trap_registry' end
    local slot = trapReg[slotIndex]
    if not slot then return false, 'slot_not_found' end

    if slot.assigned_bot_id or slot.assigned_citizenid then
        return false, 'slot_busy'
    end

    slot.assigned_bot_id = botId
    slot.assigned_citizenid = citizenid
    slot.assigned_at = os.date('%Y-%m-%d %H:%M:%S')

    -- ★ [FIX] DB callback — sessiz fail'i engelle
    MySQL.update([[
        UPDATE matrix_positions
        SET assigned_bot_id = ?, assigned_citizenid = ?, assigned_at = NOW()
        WHERE id = ?
    ]], { botId, citizenid, slot.id }, function(affected)
        if not affected or affected == 0 then
            Matrix.Log('POSITIONS', '[HATA] AssignBot DB yazimi basarisiz: slot=%s bot=%s',
                tostring(slot.id), tostring(botId))
        end
    end)

    Matrix.Log('POSITIONS', '[ATAMA] Trap #%d slot #%d (%s) -> bot=%s citizenid=%s',
        trapHouseId, slotIndex, slot.slot_type,
        tostring(botId), tostring(citizenid))
    return true, slot
end

function Matrix.Positions.ReleaseSlot(trapHouseId, slotIndex)
    trapHouseId = tonumber(trapHouseId)
    slotIndex = tonumber(slotIndex)
    if not trapHouseId or not slotIndex then return false end

    local trapReg = Matrix.Positions.Registry[trapHouseId]
    if not trapReg then return false end
    local slot = trapReg[slotIndex]
    if not slot then return false end

    slot.assigned_bot_id = nil
    slot.assigned_citizenid = nil
    slot.assigned_at = nil
    slot.under_fire = 0
    slot.using_backup = 0

    -- ★ [FIX] DB callback
    MySQL.update([[
        UPDATE matrix_positions
        SET assigned_bot_id = NULL, assigned_citizenid = NULL,
            assigned_at = NULL, under_fire = 0, using_backup = 0
        WHERE id = ?
    ]], { slot.id }, function(affected)
        if not affected or affected == 0 then
            Matrix.Log('POSITIONS', '[HATA] ReleaseSlot DB yazimi basarisiz: slot=%s',
                tostring(slot.id))
        end
    end)

    return true
end

-- =====================================================================
-- SORGU
-- =====================================================================
function Matrix.Positions.GetSlot(trapHouseId, slotIndex)
    trapHouseId = tonumber(trapHouseId)
    slotIndex = tonumber(slotIndex)
    if not trapHouseId or not slotIndex then return nil end
    local trapReg = Matrix.Positions.Registry[trapHouseId]
    if not trapReg then return nil end
    return trapReg[slotIndex]
end

function Matrix.Positions.GetAllSlots(trapHouseId)
    trapHouseId = tonumber(trapHouseId)
    if not trapHouseId then return nil end
    return Matrix.Positions.Registry[trapHouseId]
end

function Matrix.Positions.FindSlotByBot(botId)
    botId = tonumber(botId)
    if not botId then return nil, nil end
    for tid, slots in pairs(Matrix.Positions.Registry) do
        for idx, slot in pairs(slots) do
            if slot.assigned_bot_id == botId then
                return slot, tid, idx
            end
        end
    end
    return nil
end

-- =====================================================================
-- LOS KONTROLÜ (public API)
-- =====================================================================
function Matrix.Positions.CanSeeSlot(trapHouseId, slotIndex, targetX, targetY, targetZ)
    local slot = Matrix.Positions.GetSlot(trapHouseId, slotIndex)
    if not slot then return false, nil end
    return IsTargetInLOS(slot, targetX, targetY, targetZ)
end

-- =====================================================================
-- REFLEX
-- =====================================================================
function Matrix.Positions.MarkUnderFire(trapHouseId, slotIndex)
    trapHouseId = tonumber(trapHouseId)
    slotIndex = tonumber(slotIndex)
    if not trapHouseId or not slotIndex then return end

    local slot = Matrix.Positions.GetSlot(trapHouseId, slotIndex)
    if not slot then return end

    slot.under_fire = 1
    slot.last_fire_at = os.time()

    if not slot.backup_x then return end
    if slot.using_backup == 1 then return end

    slot.using_backup = 1

    -- ★ [FIX] DB callback
    MySQL.update([[
        UPDATE matrix_positions
        SET under_fire = 1, last_fire_at = NOW(), using_backup = 1
        WHERE id = ?
    ]], { slot.id }, function(affected)
        if not affected or affected == 0 then
            Matrix.Log('POSITIONS', '[HATA] MarkUnderFire DB yazimi basarisiz: slot=%s',
                tostring(slot.id))
        end
    end)

    Matrix.Log('POSITIONS',
        '[REFLEX] Trap #%d slot #%d (%s) ateş altında → yedek noktaya geçildi.',
        trapHouseId, slotIndex, slot.slot_type)
end

-- Reflex tick
CreateThread(function()
    while true do
        Wait(REFLEX_TICK_MS)

        local now = os.time()
        for tid, slots in pairs(Matrix.Positions.Registry) do
            for idx, slot in pairs(slots) do
                if slot.under_fire == 1 and slot.last_fire_at then
                    local elapsed = now - slot.last_fire_at
                    if elapsed > (REFLEX_BACKOFF_MS / 1000) and slot.using_backup == 1 then
                        slot.under_fire = 0
                        slot.using_backup = 0

                        -- ★ [FIX] DB callback
                        MySQL.update([[
                            UPDATE matrix_positions
                            SET under_fire = 0, using_backup = 0
                            WHERE id = ?
                        ]], { slot.id }, function(affected)
                            if not affected or affected == 0 then
                                Matrix.Log('POSITIONS', '[HATA] Reflex reset DB yazimi basarisiz: slot=%s',
                                    tostring(slot.id))
                            end
                        end)

                        Matrix.Log('POSITIONS',
                            '[REFLEX] Trap #%d slot #%d (%s) sakinleşti → birincil noktaya döndü.',
                            tid, idx, slot.slot_type)
                    end
                end
            end
        end
    end
end)

-- =====================================================================
-- İLKEL İŞARET SİSTEMİ (çete savaş dili)
-- =====================================================================
local function _GetPlayerTrapHouse(src)
    if not Matrix.TrapHouseInterior or not Matrix.TrapHouseInterior.GetPlayerTrapHouse then
        return nil
    end
    return Matrix.TrapHouseInterior.GetPlayerTrapHouse(src)
end

-- ★ [FIX-CRITICAL] Yetki kontrolü — sadece kendi trap house'unu görebilir
RegisterCommand('mevzidurum', function(src, args)
    if type(src) ~= 'number' or src <= 0 then return end

    local ownTrap = _GetPlayerTrapHouse(src)
    if not ownTrap then
        TriggerClientEvent('chat:addMessage', src, {
            args = { '[POSITIONS]', 'Yetkisiz — sadece kendi trap house durumunuzu gorebilirsiniz.' }
        })
        return
    end

    local tid = ownTrap
    local slots = Matrix.Positions.GetAllSlots(tid)
    if not slots then
        TriggerClientEvent('chat:addMessage', src, {
            args = { '[POSITIONS]', ('Trap #%d icin slot konfigurasyonu yok.'):format(tid) }
        })
        return
    end

    TriggerClientEvent('chat:addMessage', src, {
        args = { '[POSITIONS]', ('Trap #%d slot durumu:'):format(tid) }
    })

    for i = 1, 7 do
        local s = slots[i]
        if s then
            local status = s.assigned_bot_id and ('bot#' .. s.assigned_bot_id)
                or s.assigned_citizenid or 'bos'
            local fire = s.under_fire == 1 and ' [ATES ALTINDA]' or ''
            local backup = s.using_backup == 1 and ' [YEDEK]' or ''
            TriggerClientEvent('chat:addMessage', src, {
                args = { '[POSITIONS]',
                    ('  #%d %s | %s%s%s'):format(i, s.slot_type, status, fire, backup) }
            })
        end
    end
end, false)

-- ★ [FIX-CRITICAL] Admin-only komut (sunucu sahibi)
RegisterCommand('slotseed', function(src, args)
    if type(src) ~= 'number' or src <= 0 then return end

    if IsPlayerAceAllowed(src, 'matrix.admin') ~= true then
        TriggerClientEvent('chat:addMessage', src, {
            args = { '[POSITIONS]', 'Yetkisiz — admin yetkisi gerekli.' }
        })
        return
    end

    local tid = tonumber(args[1])
    if not tid then
        TriggerClientEvent('chat:addMessage', src, {
            args = { '[POSITIONS]', 'Kullanim: /slotseed [trapHouseId]' }
        })
        return
    end

    local ok, err = Matrix.Positions.SeedDefaults(tid)
    if ok then
        TriggerClientEvent('chat:addMessage', src, {
            args = { '[POSITIONS]', ('Trap #%d icin 7 slot olusturuldu.'):format(tid) }
        })
    else
        TriggerClientEvent('chat:addMessage', src, {
            args = { '[POSITIONS]', ('Hata: %s'):format(tostring(err)) }
        })
    end
end, false)

-- =====================================================================
-- EXPORT
-- =====================================================================
exports('Positions_GetSlot',          function(tid, idx) return Matrix.Positions.GetSlot(tid, idx) end)
exports('Positions_GetAllSlots',      function(tid) return Matrix.Positions.GetAllSlots(tid) end)
exports('Positions_FindSlotByBot',    function(botId) return Matrix.Positions.FindSlotByBot(botId) end)
exports('Positions_CanSeeSlot',       function(tid, idx, x, y, z) return Matrix.Positions.CanSeeSlot(tid, idx, x, y, z) end)
exports('Positions_AssignBot',        function(tid, idx, botId, cid) return Matrix.Positions.AssignBot(tid, idx, botId, cid) end)
exports('Positions_ReleaseSlot',      function(tid, idx) return Matrix.Positions.ReleaseSlot(tid, idx) end)
exports('Positions_MarkUnderFire',    function(tid, idx) return Matrix.Positions.MarkUnderFire(tid, idx) end)
exports('Positions_SeedDefaults',     function(tid) return Matrix.Positions.SeedDefaults(tid) end)

Matrix.Log('POSITIONS', '[BOOT] Pozisyon sistemi armed (7 slot, LOS, reflex, 0 RNG).')