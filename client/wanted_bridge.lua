-- =====================================================================
-- MATRIX WANTED BRIDGE / client/wanted_bridge.lua
-- [FAZ 1.5 — ARCADE TEMİZLİĞİ]
--
-- ESKİ: client/wanted_suppression.lua her 500ms'de wanted level'ı
--       SIFIRLIYORDU (ClearPlayerWantedLevel). Bu, GTA'nın kendi
--       suç simülasyonunu çöpe atıyordu → büro hiçbir şey öğrenemiyordu.
--
-- YENİ: Bu dosya wanted level'ı SİLMEZ, SADECE OKUR. Yıldız sayısı
-- server'a bildirilir; server bu bilgiyi büro heat map'ine, zone
-- ledger anomaly rate'ine ve pattern log'a bağlar.
--
-- FELSEFE: "Herkes aynı kurallara tabi" — oyuncu suç işlerse GTA polisi
-- gerçekten kovalar, büro gerçekten öğrenir, çete AI'ları da aynı
-- bilgiyi hak ederek kazanır.
-- =====================================================================

if not Config.Features or Config.Features.WantedBridge == false then
    print('[WANTED_BRIDGE] Devre disi (Config.Features.WantedBridge = false)')
    return
end

local PlayerId             = PlayerId
local PlayerPedId          = PlayerPedId
local GetPlayerWantedLevel = GetPlayerWantedLevel
local GetEntityCoords      = GetEntityCoords
local GetGameTimer         = GetGameTimer

-- Raporlama aralığı — her frame değil, 5 saniyede bir
local REPORT_INTERVAL_MS = 5000

-- Son gönderilen yıldız (aynı değeri tekrar göndermemek için)
local _lastReportedWanted = -1
local _lastReportAt       = 0

-- Pencere içindeki en yüksek yıldız (anlık yakalamak için)
local _peakWantedSinceReport = 0

CreateThread(function()
    while true do
        Wait(1000)
        local pid    = PlayerId()
        local wanted = GetPlayerWantedLevel(pid)
        local now    = GetGameTimer()

        if wanted > _peakWantedSinceReport then
            _peakWantedSinceReport = wanted
        end

        if (now - _lastReportAt) >= REPORT_INTERVAL_MS then
            if _peakWantedSinceReport > 0 then
                local ped    = PlayerPedId()
                local coords = GetEntityCoords(ped)
                TriggerServerEvent('matrix:server:wantedBridge:report', _peakWantedSinceReport, {
                    x = coords.x, y = coords.y, z = coords.z
                })
                _lastReportedWanted = _peakWantedSinceReport
            elseif _lastReportedWanted > 0 then
                TriggerServerEvent('matrix:server:wantedBridge:report', 0, nil)
                _lastReportedWanted = 0
            end

            _peakWantedSinceReport = 0
            _lastReportAt          = now
        end
    end
end)

-- Debug komutu
RegisterCommand('wantedbridge', function()
    local pid    = PlayerId()
    local wanted = GetPlayerWantedLevel(pid)
    local coords = GetEntityCoords(PlayerPedId())
    local msg = ('[WANTED_BRIDGE] Level=%d | Son-Rapor=%d | Konum=(%.1f,%.1f,%.1f)'):format(
        wanted, _lastReportedWanted, coords.x, coords.y, coords.z)
    print(msg)
    TriggerEvent('chat:addMessage', {
        color = { 110, 255, 140 },
        args  = { '[MATRIX]', msg }
    })
end, false)

print('[WANTED_BRIDGE] Yildiz kopru aktif — GTA wanted level artik SILINMEZ, OKUNUR.')