-- vbs_core_matrix / server/missions.lua
-- FAZ 2.6 P0 — iskelet. Tip handler'ları P1'de register edilir.

Matrix.Missions = Matrix.Missions or {}
local M = Matrix.Missions
local TYPES   = { 'uretim','nakliye','sabotaj','infaz' }
local STATES  = { offered=true, accepted=true, in_progress=true,
                  completed=true, failed=true }
local handlers = {}
local cache = {}          -- missionId -> row (RAM ayna)
local TICK_MS = 1000      -- seyreltme (Bölüm 8: [C])

local function log(...)
  local n = select('#', ...)
  local p = {}
  for i=1,n do p[i] = tostring(select(i,...)) end
  Matrix.Log('[MISSIONS] ' .. table.concat(p, ' '), '')
end

function M.Register(mtype, handler)
  assert(handlers[mtype] == nil, 'duplicate mission type: '..mtype)
  assert(type(handler) == 'table' and type(handler.onComplete) == 'function',
         'handler.onComplete zorunlu: '..mtype)
  handlers[mtype] = handler
  log('tip kayitli:', mtype)
end

local function loadActive()
  local ok, rows = pcall(function()
    return MySQL.query.await(
      "SELECT * FROM matrix_missions WHERE state IN ('offered','accepted','in_progress')")
  end)
  if not ok or not rows then
    log('HATA: loadActive basarisiz:', tostring(rows)); return
  end
  for _, r in ipairs(rows) do cache[r.id] = r end
  log(('aktif gorev: %d'):format(#rows))
end

function M.Offer(giverBotId, citizenid, mtype, payload, rewards)
  if not handlers[mtype] then return false, 'tip_yok' end
  if type(rewards) ~= 'table' then return false, 'odul_yok' end
  local deadline = GetGameTimer() + (rewards.duration_s or 600) * 1000
  local ok, id = pcall(function()
    return MySQL.insert.await([[
      INSERT INTO matrix_missions
        (mission_type,giver_bot_id,assignee_citizenid,state,
         target_payload,reward_cash,reward_rep,reward_heat,deadline_tick)
      VALUES (?,?,?,'offered',?,?,?,?,?)
    ]], { mtype, giverBotId, citizenid,
          json.encode(payload or {}),
          rewards.cash or 0, rewards.rep or 0, rewards.heat or 0,
          deadline })
  end)
  if not ok or not id then log('HATA: Offer insert:', tostring(id)); return false end
    cache[id] = { id=id, mission_type=mtype, giver_bot_id=giverBotId,
                assignee_citizenid=citizenid, state='offered',
                target_payload=payload or {},
                reward_cash=rewards.cash or 0,
                reward_rep=rewards.rep or 0,
                reward_heat=rewards.heat or 0,
                deadline_tick=deadline }
  TriggerEvent('matrix:internal:mission:offered', id, citizenid, mtype)
  return true, id
end

local function setState(id, newState, extra)
  if not STATES[newState] then return false end
  local row = cache[id]; if not row then return false, 'yok' end
  local ok, err = pcall(function()
    MySQL.update.await(
      'UPDATE matrix_missions SET state=?, target_payload=? WHERE id=?',
      { newState, json.encode(extra or row.target_payload or {}), id })
  end)
  if not ok then log('HATA: setState:', tostring(err)); return false end
  row.state = newState; if extra then row.target_payload = extra end
  if newState == 'completed' or newState == 'failed' then
    cache[id] = nil
    TriggerEvent('matrix:internal:mission:closed', id, newState)
  end
  return true
end

function M.Accept(id, citizenid)
  local row = cache[id]; if not row or row.state ~= 'offered' then return false end
  if row.assignee_citizenid and row.assignee_citizenid ~= citizenid then
    return false, 'baska_oyuncu'
  end
  return setState(id, 'accepted', row.target_payload)
end

function M.Progress(id, payload) return setState(id, 'in_progress', payload) end

function M.Complete(id)
  local row = cache[id]; if not row then return false end
  local h = handlers[row.mission_type]
  if h and h.onComplete then
    local ok, err = pcall(h.onComplete, row)
    if not ok then log('HATA: onComplete:', tostring(err)); return false end
  end
  return setState(id, 'completed')
end

function M.Fail(id, reason)
  local row = cache[id]; if not row then return false end
  local h = handlers[row.mission_type]
  if h and h.onFail then pcall(h.onFail, row, reason) end
  return setState(id, 'failed', {reason=reason})
end

-- ═══════════ FAZ 2.6 / P1 — TİP HANDLER'LARI ═══════════

local function grantRewards(row)
  local cid = row.assignee_citizenid
  if not cid or cid == '' then return end

  if (row.reward_cash or 0) > 0 then
    local ok, Player = pcall(function()
      return Matrix.QBX:GetPlayerByCitizenId(cid)
    end)
    if ok and Player and Player.Functions then
      Player.Functions.AddMoney('cash', row.reward_cash, 'mission')
      log('odul_cash:', cid, ('%d'):format(row.reward_cash))
    else
      log('odul_gec:', cid, 'player_offline')
    end
  end

  -- Heat: FAZ 3'te LSPD IssueWantedForCrime'a köprülenir
  if (row.reward_heat or 0) > 0 then
    TriggerEvent('matrix:internal:missions:apply_heat', cid, row.reward_heat, 'mission')
    log('odul_heat:', cid, ('%d'):format(row.reward_heat))
  end

  -- Rep: FAZ 3'te matrix_reputation tablosu gelir
  if (row.reward_rep or 0) > 0 then
    log('odul_rep:', cid, ('%d'):format(row.reward_rep))
  end
end

local function applyPenalty(row, reason)
  local cid = row.assignee_citizenid
  if not cid or cid == '' then return end
  TriggerEvent('matrix:internal:missions:apply_heat', cid, 3,
               'mission_fail:'..tostring(reason))
  log('ceza:', cid, tostring(reason))
end



M.Register('uretim', {
  onComplete = function(row) grantRewards(row) end,
  onFail     = function(row, reason) applyPenalty(row, reason) end,
})

M.Register('nakliye', {
  onComplete = function(row) grantRewards(row) end,
  onFail     = function(row, reason) applyPenalty(row, reason) end,
})

M.Register('sabotaj', {
  onComplete = function(row) grantRewards(row) end,
  onFail     = function(row, reason) applyPenalty(row, reason) end,
})

M.Register('infaz', {
  onComplete = function(row)
    grantRewards(row)
    local tp = row.target_payload or {}
    if tp.target_bot_id then
      TriggerEvent('matrix:internal:crime:log_kill', row.assignee_citizenid,
                   tp.target_bot_id, 'mission_infaz')
    end
  end,
  onFail     = function(row, reason) applyPenalty(row, reason) end,
})

-- Diğer modüller bu event'i tetikler (kitchen, logistics, crime_witness):
-- TriggerEvent('matrix:internal:missions:progress', citizenid, mtype, {amount=5})
AddEventHandler('matrix:internal:missions:progress', function(cid, mtype, delta)
  if type(cid) ~= 'string' or type(mtype) ~= 'string' then return end
  for id, row in pairs(cache) do
    if row.assignee_citizenid == cid
       and row.mission_type == mtype
       and (row.state == 'accepted' or row.state == 'in_progress') then
      local cur = row.target_payload or {}
      for k, v in pairs(delta or {}) do
        if type(v) == 'number' and type(cur[k]) == 'number' then
          cur[k] = cur[k] + v
        else
          cur[k] = v
        end
      end
      M.Progress(id, cur)
      if cur.target_reached == true then M.Complete(id) end
    end
  end
end)


-- Heat köprüsü: mission → en yakın trap house decryption_confidence
AddEventHandler('matrix:internal:missions:apply_heat', function(cid, amount, reason)
  if type(cid) ~= 'string' or type(amount) ~= 'number' or amount <= 0 then return end
  local ok, Player = pcall(function() return Matrix.QBX:GetPlayerByCitizenId(cid) end)
  if not ok or not Player or not Player.PlayerData then
    log('heat_gec:', cid, 'player_offline'); return
  end
  local src = Player.PlayerData.source
  local ped = GetPlayerPed(src)
  if not ped or ped <= 0 then return end
  local coords = GetEntityCoords(ped)
  local best, bestDist = nil, math.huge
  for id, house in pairs(Matrix.TrapHouses or {}) do
    local hc = house.coords
    if hc then
      local d = #(coords - hc)
      if d < bestDist then best, bestDist = id, d end
    end
  end
  if not best then log('heat_gec:', cid, 'trap_yok'); return end
  if Matrix.Bureau and Matrix.Bureau.AdvanceDecryption then
    local ok2, err = pcall(Matrix.Bureau.AdvanceDecryption, best, amount * 0.035)
    if ok2 then
      log(('heat: cid=%s trap=%s amt=%.4f reason=%s')
          :format(cid, tostring(best), amount * 0.035, tostring(reason)))
    else
      log('heat_hata:', tostring(err))
    end
  end
end)

-- Tick: deadline kontrolü (deterministik, 1sn)
CreateThread(function()
  while true do
    Wait(TICK_MS)
    local now = GetGameTimer()
    for id, row in pairs(cache) do
      if row.deadline_tick and now > row.deadline_tick and row.state ~= 'offered' then
        M.Fail(id, 'deadline')
      end
    end
  end
end)

-- TEST SCAFFOLD (P5'te SİLİNECEK):
-- Kullanım: /missions_test_offer <citizenid> <uretim|nakliye|sabotaj|infaz>
RegisterCommand('missions_test_offer', function(src, args)
  if type(args) ~= 'table' or #args < 2 then
    print('[MISSIONS_TEST] kullanim: /missions_test_offer <cid> <tip>'); return
  end
  local cid, mtype = tostring(args[1]), tostring(args[2])
  local ok, id = M.Offer(nil, cid, mtype, { target_reached=false },
                         { cash=500, rep=1, heat=1, duration_s=60 })
  print(('[MISSIONS_TEST] Offer cid=%s tip=%s → ok=%s id=%s')
        :format(cid, mtype, tostring(ok), tostring(id)))
end, false)

-- ═══════════ FAZ 2.6 / P2d — HUB AUTO-OFFER ═══════════

local OFFER_COOLDOWN_MS = 120000   -- aynı oyuncu + hub için 2 dk
local HUB_PROXIMITY     = 30.0
local OFFER_SCAN_MS     = 5000
local lastOffer = {}               -- [cid..':'..hubId] = GetGameTimer()

local MISSION_REWARDS = {
  uretim  = { cash=500,  rep=1, heat=1, duration_s=600  },
  nakliye = { cash=800,  rep=1, heat=2, duration_s=900  },
  sabotaj = { cash=1200, rep=2, heat=3, duration_s=1200 },
  infaz   = { cash=2000, rep=3, heat=5, duration_s=1800 },
}

local function detIdx(seed, n)
  local sum = 0
  for i = 1, #seed do
    sum = (sum * 31 + string.byte(seed, i)) % 100000
  end
  return (sum % n) + 1
end

local function hasActiveMission(cid)
  for _, row in pairs(cache) do
    if row.assignee_citizenid == cid
       and (row.state == 'accepted' or row.state == 'in_progress') then
      return true
    end
  end
  return false
end

CreateThread(function()
  Wait(15000)
  while true do
    Wait(OFFER_SCAN_MS)
    print(('[MISSIONS_TICK] scan | players=%d'):format(#GetPlayers()))
    local ok, hubs = pcall(Matrix.DistrictHubs.GetAll)
    if ok and type(hubs) == 'table' then
      for _, hub in pairs(hubs) do
        if hub.active and not hub.locked and hub.coords then
          for _, srcStr in ipairs(GetPlayers()) do
            local srcNum = tonumber(srcStr)
            if srcNum then
              local ped = GetPlayerPed(srcNum)
              if ped and ped > 0 then
                local pc = GetEntityCoords(ped)
                print(('[MISSIONS_TICK] hub=%s pedsrc=%d dist=%.1f')
                       :format(tostring(hub.id), srcNum, #(pc - hub.coords)))
                if #(pc - hub.coords) <= HUB_PROXIMITY then
                  local ok2, Player = pcall(function()
                    return Matrix.QBX:GetPlayer(srcNum)
                  end)
                  if ok2 and Player and Player.PlayerData
                     and Player.PlayerData.citizenid then
                    local cid = Player.PlayerData.citizenid
                    if not hasActiveMission(cid) then
                      local key = cid .. ':' .. tostring(hub.id)
                      local now = GetGameTimer()
                      if not lastOffer[key]
                         or (now - lastOffer[key]) >= OFFER_COOLDOWN_MS then
                        lastOffer[key] = now
                        local seed  = cid .. tostring(hub.id)
                                      .. tostring(math.floor(now / 60000))
                        local mtype = TYPES[detIdx(seed, #TYPES)]
                        local rew   = MISSION_REWARDS[mtype]
                        local okO, idO = M.Offer(nil, cid, mtype,
                          { hub_id=hub.id, target_reached=false }, rew)
                        if okO then
                          log(('hub_offer: cid=%s hub=%s tip=%s id=%s')
                              :format(cid, tostring(hub.id),
                                      mtype, tostring(idO)))
                        end
                      end
                    end
                  end
                end
              end
            end
          end
        end
      end
    end
  end
end)

-- TEST SCAFFOLD (P5'te SİLİNECEK):
RegisterCommand('missions_test_hub', function(src, args)
  if type(args) ~= 'table' or #args < 4 then
    print('[MISSIONS_TEST] kullanim: /missions_test_hub <trapId> <x> <y> <z>')
    return
  end
  local trapId = tonumber(args[1])
  local x, y, z = tonumber(args[2]), tonumber(args[3]), tonumber(args[4])
  if not (trapId and x and y and z) then
    print('[MISSIONS_TEST] sayi gecersiz'); return
  end
  local ok, reason = Matrix.DistrictHubs.Assign(trapId, 'CHAOS-FIXTURE-HUB',
                                                vector3(x,y,z), nil)
  print(('[MISSIONS_TEST] hub assign → ok=%s reason=%s')
        :format(tostring(ok), tostring(reason)))
end, false)

AddEventHandler('onResourceStart', function(res)
  if res ~= GetCurrentResourceName() then return end
  loadActive()
  log(('hazir | tipler=%d | aktif=%d'):format(
      (function() local n=0 for _ in pairs(handlers) do n=n+1 end return n end)(),
      (function() local n=0 for _ in pairs(cache)   do n=n+1 end return n end)()))
end)

-- TEST SCAFFOLD (P5'te SİLİNECEK):
RegisterCommand('missions_probe', function(src)
  local n=0 for _ in pairs(cache) do n=n+1 end
  print(('[MISSIONS_PROBE] aktif=%d tipler=%d'):format(n, #TYPES))
end, false)

RegisterCommand('missions_test_complete', function(src, args)
  if type(args) ~= 'table' or #args < 1 then
    print('[MISSIONS_TEST] kullanim: /missions_test_complete <id>'); return
  end
  local id = tonumber(args[1])
  if not id then print('[MISSIONS_TEST] id gecersiz'); return end
  local ok, err = M.Complete(id)
  print(('[MISSIONS_TEST] Complete id=%s → ok=%s err=%s')
        :format(tostring(id), tostring(ok), tostring(err)))
end, false)

RegisterCommand('missions_test_fail', function(src, args)
  if type(args) ~= 'table' or #args < 1 then
    print('[MISSIONS_TEST] kullanim: /missions_test_fail <id> [reason]'); return
  end
  local id = tonumber(args[1])
  if not id then print('[MISSIONS_TEST] id gecersiz'); return end
  local reason = args[2] or 'manual_test'
  local ok, err = M.Fail(id, reason)
  print(('[MISSIONS_TEST] Fail id=%s reason=%s → ok=%s err=%s')
        :format(tostring(id), tostring(reason), tostring(ok), tostring(err)))
end, false)