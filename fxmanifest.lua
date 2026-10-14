fx_version 'cerulean'
game 'gta5'
lua54 'yes'

author 'projeFivem'
description 'vbs_core_matrix - Katman 1-8 Birlesik Motor'
version '1.7.1'

shared_scripts {
    '@ox_lib/init.lua',
    'shared/config.lua',
    'shared/log.lua',
    'shared/crypto.lua'
}

client_scripts {
    'client/hud.lua',
    'client/debug_map.lua',
    'client/trap_house_client.lua',
    'client/composer_intro.lua',
    'client/mercenary_followers.lua',
    'client/humint_stalking.lua',
    'client/anti_glitch.lua',
    'client/trigger_discipline.lua',
    'client/wanted_bridge.lua',
    'client/matrix_events_handler.lua',
    'client/matrix_session1_client.lua',
    'client/botany_client.lua',
    'client/civilian_vetting.lua',
    'client/chemical_workbench_client.lua',
    'client/prop_placement.lua',
    'client/gang_presence.lua',
    'client/crime_witness_bridge.lua',
    'client/chaos_attacker.lua'
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',

    -- ── ★ NETWORK GUARD (EN BAŞTA OLMALI) ──
    'server/matrix_network_guard.lua',

    -- ── Çekirdek ──
    'server/main.lua',
    'server/debug_map.lua',

    -- ── Katman 1-5: Core / Bureau / Market ──
    'server/forensics.lua',
    'server/recruitment.lua',
    'server/bureau.lua',
    'server/district_hubs.lua',
    'server/kitchen.lua',
    'server/logistics.lua',
    'server/market.lua',

    -- ── Katman 6: Trap House / Rendezvous / Workbench ──
    'server/blackmarket.lua',
    'server/rendezvous.lua',
    'server/trap_house_interior.lua',
    'server/workbench.lua',
    'server/door_reinforcement.lua',

    -- ── Katman 7-8 ──
    'server/wound_system.lua',
    'server/underworld_network.lua',
    'server/gang_hoods.lua',
    'server/mercenary_followers.lua',
    'server/hitsquad.lua',
    'server/phone_bridge.lua',
    'server/police_raid.lua',
    'server/wanted_bridge.lua',              

    -- ── Diagnostik + Cognition + Telemetri ──
    'server/matrix_diagnostics.lua',
    'server/cognition_core.lua',
    'server/player_telemetry.lua',

    -- ── Session 1-3 ──
    'server/matrix_session1_bridge.lua',
    'server/botany_core.lua',
    'server/infestation.lua',
    'server/odor_core.lua',

    -- ── Session 4 ──
    'server/chemical_workbench.lua',

    -- ── ★ SESSION 4.99 ──
    'server/crack_chemistry.lua',
    'server/meth_chemistry.lua',
    'server/botany_autonomy.lua',
    'server/cellular_comms.lua',
    'server/prop_registry.lua',

       -- ── ★ SOKAK PED'LERİ (yeni — Feature Flag kontrollü) ──
    'server/gang_presence.lua',

-- ── ★ FAZ 2.6 — GÖREV SİSTEMİ (CHAOS'TAN ÖNCE) ──
    'server/missions.lua',

    -- ── ★ CHAOS ENGINE (YAMYAM MODU) ──
    'server/matrix_chaos.lua',
    'server/matrix_chaos_cannibal.lua',
    'server/matrix_chaos_hardcore_world.lua',
    'server/matrix_chaos_hardcore_transition.lua',
    'server/matrix_chaos_hardcore_bridge.lua',
    'server/matrix_chaos_hardcore_auth.lua',
    'server/matrix_chaos_hardcore_ui.lua',

    'server/lspd_units.lua',
    'server/crime_witness.lua',
    'server/debrief.lua',
    'server/positions.lua'
}


files {
    'sounds/*.ogg'
}

dependencies {
    'ox_lib',
    'qbx_core',
    'oxmysql',
    'ox_inventory',
    'ox_target',
    'xsound',
    'bob74_ipl'
}