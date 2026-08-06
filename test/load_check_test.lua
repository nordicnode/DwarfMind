-- Load EVERY DwarfMind module under the DFHack-shaped mock and assert it
-- loads cleanly — codifying the AGENTS.md "top-level require check" rule.
-- Any df.global / dfhack.persistent / dfhack.burrows access at module-load
-- time (which crashes at the main-menu screen) fails here.

local MODULES = {
    'ai_core.lua', 'sensors.lua', 'actuators.lua', 'logger.lua',
    'build_layer.lua', 'utils.lua',
    'reflex_access_security.lua', 'reflex_auto_container.lua',
    'reflex_beds.lua', 'reflex_bookkeeper_audit.lua', 'reflex_burrow.lua',
    'reflex_butcher.lua', 'reflex_cemetery.lua', 'reflex_cemetery_slab.lua',
    'reflex_cleanup.lua', 'reflex_clothing.lua', 'reflex_defense.lua',
    'reflex_distress.lua', 'reflex_farming.lua', 'reflex_garbage.lua',
    'reflex_geld.lua', 'reflex_hospitality.lua', 'reflex_hydrology.lua',
    'reflex_idle.lua', 'reflex_infirmary_supply.lua', 'reflex_justice.lua',
    'reflex_medical.lua', 'reflex_melt_coordinator.lua',
    'reflex_military_gear.lua', 'reflex_mood_helper.lua',
    'reflex_noble_demands.lua', 'reflex_orchestrator.lua',
    'reflex_pasture.lua', 'reflex_potash_chain.lua', 'reflex_production.lua',
    'reflex_quarantine.lua', 'reflex_seedwatch.lua', 'reflex_siege_ammo.lua',
    'reflex_soap_chain.lua', 'reflex_squad_alert.lua', 'reflex_stress.lua',
    'reflex_tantrum_watch.lua', 'reflex_trade.lua',
    'reflex_trap_logistics.lua', 'reflex_vermin_control.lua',
    'reflex_woodcutter.lua',
}

for _, path in ipairs(MODULES) do
    it(('loads cleanly at top level: %s'):format(path), function()
        load_module(path)
    end)
end
