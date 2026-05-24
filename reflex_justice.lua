-- DwarfMind reflex: justice, crime, and law enforcement audit.
-- Monitors the Sheriff/Captain of the Guard appointment, jailed prisoner
-- wellness, and available justice infrastructure (chains and cages).
-- Logs critical warnings but does not auto-convict — that remains a player decision.
--@ module = true

local _ENV = mkmodule('dwarfmind/reflex_justice')

local sensors   = reqscript('dwarfmind/sensors')
local actuators = reqscript('dwarfmind/actuators')
local logger    = reqscript('dwarfmind/logger')
local log       = logger.for_module('reflex_justice')

-- Cooldown to avoid spamming alerts.
local ALERT_COOLDOWN = 6000
local last_alert = -math.huge

-- Minimum restraints to maintain for justice enforcement.
local MIN_CHAINS = 2
local MIN_CAGES = 2

function run()
    if not sensors.is_fort_loaded() then return end

    local now, tick_ok = sensors.current_tick()
    if not tick_ok then now = 0 end
    if (now - last_alert) < ALERT_COOLDOWN then return end

    local status, ok = sensors.check_justice_status()
    if not ok then
        log.warn('check_justice_status failed')
        return
    end

    local alert_issued = false

    -- 1. Missing law enforcement officer
    if not status.has_sheriff then
        log.warn('CRITICAL JUSTICE: no Sheriff or Captain of the Guard is appointed! Crimes will go unpunished.')
        alert_issued = true
    else
        log.debug('justice audit: law enforcement officer is present')
    end

    -- 2. Jailed prisoner wellness
    if status.jailed_count > 0 then
        log.info(string.format('justice audit: %d prisoner(s) currently serving sentences', status.jailed_count))
        if status.jailed_distressed > 0 then
            log.warn(string.format('CRITICAL JUSTICE: %d jailed prisoner(s) are showing signs of hunger or thirst! Ensure buckets and food reach the jail.', status.jailed_distressed))
            alert_issued = true
        end
    end

    -- 3. Justice infrastructure deficit
    local chain_total = (status.chain_count or 0) + (status.queued_chains or 0)
    local cage_total = (status.cage_count or 0) + (status.queued_cages or 0)

    if chain_total < MIN_CHAINS then
        log.warn(string.format('justice infrastructure: only %d chain(s) available (target %d). New crimes cannot be punished without restraints.', chain_total, MIN_CHAINS))
        alert_issued = true
    end

    if cage_total < MIN_CAGES then
        log.warn(string.format('justice infrastructure: only %d cage(s) available (target %d). New crimes cannot be punished without restraints.', cage_total, MIN_CAGES))
        alert_issued = true
    end

    if alert_issued then
        last_alert = now
    else
        log.debug(string.format('justice audit healthy: sheriff=%s, prisoners=%d, chains=%d, cages=%d',
            tostring(status.has_sheriff), status.jailed_count, chain_total, cage_total))
    end
end

function reset()
    last_alert = -math.huge
end

return _ENV
