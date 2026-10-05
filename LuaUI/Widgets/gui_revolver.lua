--------------------------------------------------------------------------------
--------------------------------------------------------------------------------

function widget:GetInfo()
	return {
		name      = "Revolver",
		desc      = "Fleet manager for Magpies. Groups them into six wings, shows how many each target needs, keeps shots for ordered targets, balances pads, maps enemy anti-air and records every sortie.",
		author    = "QrowZK",
		date      = "October 2026",
		license   = "GNU GPL, v2 or later",
		layer     = 10,
		enabled   = false,
		handler   = true,
	}
end

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- Speedups

local spGetUnitDefID           = Spring.GetUnitDefID
local spGetUnitAllyTeam        = Spring.GetUnitAllyTeam
local spGetUnitHealth          = Spring.GetUnitHealth
local spGetUnitPosition        = Spring.GetUnitPosition
local spGetUnitRulesParam      = Spring.GetUnitRulesParam
local spGetUnitCurrentCommand  = Spring.GetUnitCurrentCommand
local spGetUnitStates          = Spring.GetUnitStates
local spGetUnitIsDead          = Spring.GetUnitIsDead
local spValidUnitID            = Spring.ValidUnitID
local spGiveOrderToUnitArray   = Spring.GiveOrderToUnitArray
local spGiveOrderToUnit        = Spring.GiveOrderToUnit
local spGetMouseState          = Spring.GetMouseState
local spTraceScreenRay         = Spring.TraceScreenRay
local spIsPosInLos             = Spring.IsPosInLos
local spGetGroundHeight        = Spring.GetGroundHeight

local floor, ceil, sqrt, min, max = math.floor, math.ceil, math.sqrt, math.min, math.max
local pi, cos, sin = math.pi, math.cos, math.sin

local CMD_ATTACK      = CMD.ATTACK
local CMD_MOVE        = CMD.MOVE
local CMD_FIRE_STATE  = CMD.FIRE_STATE
local CMD_OPT_SHIFT   = CMD.OPT_SHIFT

local customCmds      = VFS.Include("LuaRules/Configs/customcmds.lua")
local CMD_REARM       = customCmds.REARM
local CMD_FIND_PAD    = customCmds.FIND_PAD
local CMD_RETREAT     = customCmds.RETREAT
local CMD_LOOP_ATTACK = customCmds.LOOP_ATTACK
local CMD_SET_TARGET  = customCmds.UNIT_SET_TARGET

local FIRESTATE_HOLD = 0
local FIRESTATE_FREE = 2

local defs = VFS.Include("LuaUI/Configs/revolver_defs.lua")

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- Unit data

local MAGPIE_NAME = "planesupport"
local magpieDefID = UnitDefNames[MAGPIE_NAME] and UnitDefNames[MAGPIE_NAME].id

local WING_COUNT = 6
local WING_LETTER = {"A", "B", "C", "D", "E", "F"}

local magpieStats = {
	range = 580,
	speed = 252,
	maxHealth = 900,
	cost = 250,
	bursts = 30,
	damagePerBurst = 64,
	rearmSeconds = 5,
}

local planesArmour = (Game.armorTypes and Game.armorTypes.planes) or 0
local repairCostFactor = Game.repairEnergyCostFactor or 0.6667

do
	local ud = magpieDefID and UnitDefs[magpieDefID]
	if ud then
		magpieStats.speed = ud.speed or magpieStats.speed
		magpieStats.maxHealth = ud.health or magpieStats.maxHealth
		magpieStats.cost = ud.metalCost or magpieStats.cost
		magpieStats.bursts = tonumber(ud.customParams.shots_per_refuel) or magpieStats.bursts
		magpieStats.rearmSeconds = tonumber(ud.customParams.reammoseconds) or magpieStats.rearmSeconds
		local weapon = ud.weapons and ud.weapons[1]
		local wd = weapon and WeaponDefs[weapon.weaponDef]
		if wd then
			magpieStats.range = wd.range or magpieStats.range
			local damage = wd.damages and (wd.damages[0] or wd.damages[1])
			if damage then
				magpieStats.damagePerBurst = damage*(wd.salvoSize or 1)*(wd.projectiles or 1)
			end
		end
	end
end

-- Pads: anything with customParams.ispad
local padDefs = {}
for unitDefID = 1, #UnitDefs do
	local ud = UnitDefs[unitDefID]
	if ud.customParams and ud.customParams.ispad then
		padDefs[unitDefID] = {
			cap = tonumber(ud.customParams.pad_count) or 1,
			bp = tonumber(ud.customParams.pad_bp) or 2.5,
			mobile = not ud.isImmobile,
		}
	end
end

-- Anti-air: every weapon that can shoot fixed-wing aircraft
local aaDefs = {}
local fighterDefs = {}
for unitDefID = 1, #UnitDefs do
	local ud = UnitDefs[unitDefID]
	local dps, range = 0, 0
	local longReload = false
	local stockShot = false
	if ud.weapons then
		for i = 1, #ud.weapons do
			local weapon = ud.weapons[i]
			if weapon.onlyTargets and weapon.onlyTargets.fixedwing then
				local wd = WeaponDefs[weapon.weaponDef]
				if wd then
					local damage = wd.damages and (wd.damages[planesArmour] or wd.damages[0]) or 0
					local shots = (wd.salvoSize or 1)*(wd.projectiles or 1)
					local reload = max(wd.reload or 1, 1/30)
					dps = dps + damage*shots/reload
					range = max(range, wd.range or 0)
					if wd.stockpile then
						stockShot = damage*shots
					end
					if reload >= 6 then
						longReload = max(longReload or 0, reload)
					end
				end
			end
		end
	end
	if dps > 0 and range > 0 and unitDefID ~= magpieDefID then
		aaDefs[unitDefID] = {
			dps = dps,
			range = range,
			ttk = magpieStats.maxHealth/dps,
			static = ud.isImmobile,
			reload = longReload,
			name = ud.humanName or ud.name,
			-- Stockpiled weapons: seconds per missile and damage per missile.
			stockTime = stockShot and tonumber(ud.customParams.stockpiletime) or nil,
			stockShot = stockShot or nil,
		}
		if aaDefs[unitDefID].stockTime then
			aaDefs[unitDefID].dps = 0 -- its damage comes from the stockpile, counted per missile
		end
		if ud.canFly then
			fighterDefs[unitDefID] = true
		end
	end
end

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- Options

local hud = {x = 160, y = 220, radius = 92, chamber = 30}
local ledgerPanel = {x = 20, y = 260, w = 380, h = 220}

local Fire, Mark, ClearMarks, Recall, SelectWing, SelectReady, SetApproach, PoolPartial, ToggleCalibration
local ToggleMenu, AssignSelected

local ROOT = 'Settings/Unit Behaviour/Revolver'
local PATH = {
	cylinder = ROOT .. '/Cylinder',
	reload   = ROOT .. '/Reload',
	sights   = ROOT .. '/Sights',
	trigger  = ROOT .. '/Trigger',
	radar    = ROOT .. '/Radar',
	ledger   = ROOT .. '/Ledger',
	grip     = ROOT .. '/Grip',
}

local function Switch(name, desc, value, path)
	return {name = name, desc = desc, type = 'bool', value = value, path = path, noHotkey = true}
end

options_path = ROOT
options_order = {
	-- Cylinder
	'auto_wing', 'wing_size', 'assign_mode', 'ready_ammo', 'ready_health', 'spare_wing', 'show_hud', 'wing_labels', 'fleet_advisor',
	-- Reload
	'pad_balance', 'retreat_state',
	-- Sights
	'show_card', 'live_correction', 'allocate', 'horizon', 'auto_style', 'slow_chain', 'kill_confirm',
	-- Trigger
	'hold_fire', 'release_near_target', 'time_on_target', 'staging_distance', 'rotate_fire',
	-- Radar
	'threat_map', 'route_lines', 'stale_intel', 'stale_seconds', 'route_alert', 'fighter_alert', 'fighter_pullback', 'stockpile_watch', 'stockpile_speed', 'stockpile_cap', 'reload_tracking',
	-- Ledger
	'ledger_tracking', 'show_ledger', 'ledger_view', 'career_history', 'export_csv',
	-- Grip
	'sounds', 'open_menu', 'fire', 'mark', 'clear_marks', 'recall', 'select_ready',
	'select_1', 'select_2', 'select_3', 'select_4', 'select_5', 'select_6',
	'assign_1', 'assign_2', 'assign_3', 'assign_4', 'assign_5', 'assign_6',
	'approach', 'pool', 'calibrate',
}
options = {
	-- Cylinder
	auto_wing = Switch('Put new Magpies in wings', 'New Magpies join a wing as they leave the plant. Off: assign them yourself with the Assign keys.', true, PATH.cylinder),
	wing_size = {name = 'Wing size', desc = 'Most Magpies in one wing. Extra Magpies go to the next wing.', type = 'number', value = 12, min = 1, max = 40, step = 1, path = PATH.cylinder},
	assign_mode = {
		name = 'New Magpies join', type = 'radioButton', value = 'fill', path = PATH.cylinder,
		items = {
			{key = 'fill', name = 'Fill one wing at a time'},
			{key = 'round', name = 'Wings in turn'},
		},
	},
	ready_ammo = {name = 'Ready at ammo (%)', desc = 'A wing is chambered when its average ammo reaches this.', type = 'number', value = 90, min = 10, max = 100, step = 5, path = PATH.cylinder},
	ready_health = {name = 'Ready at health (%)', desc = 'A wing is chambered when its average health reaches this.', type = 'number', value = 70, min = 10, max = 100, step = 5, path = PATH.cylinder},
	spare_wing = Switch('Use wing F as the spare wing', 'Half-empty Magpies are gathered into wing F so full wings stay chambered.', false, PATH.cylinder),
	show_hud = Switch('Show cylinder', nil, true, PATH.cylinder),
	wing_labels = Switch('Wing labels over Magpies', nil, true, PATH.cylinder),
	fleet_advisor = Switch('Fleet and pad advisor', 'Pad slots against what the fleet needs, under the cylinder and in the ledger.', true, PATH.cylinder),

	-- Reload
	pad_balance = Switch('Balance pads', 'Send returning Magpies to the pad with the shortest wait.', true, PATH.reload),
	retreat_state = {
		name = 'Damage triage (retreat setting for wings)', type = 'radioButton', value = 'keep', path = PATH.reload,
		items = {
			{key = 'keep', name = 'Leave as is'},
			{key = '1', name = 'Retreat at 30%'},
			{key = '2', name = 'Retreat at 65%'},
			{key = '3', name = 'Retreat at 99%'},
		},
	},

	-- Sights
	show_card = Switch('Breakpoint card on hover', nil, true, PATH.sights),
	live_correction = Switch('Correct for health and armour', 'Scale breakpoints by the target\'s current health and closed armour.', true, PATH.sights),
	allocate = Switch('Split wings across targets', 'Off: Fire sends one whole chambered wing per target.', true, PATH.sights),
	horizon = {
		name = 'Kill within', desc = 'How fast a target should die. Sets how many Magpies Fire sends.', type = 'radioButton', value = '2', path = PATH.sights,
		items = {
			{key = '1', name = '1 pass'}, {key = '2', name = '2 passes'}, {key = '3', name = '3 passes'},
			{key = '5', name = '5 passes'}, {key = '99', name = 'One sortie'},
		},
	},
	auto_style = Switch('Pick Strafe or Loopback per target', nil, true, PATH.sights),
	slow_chain = Switch('Slow chain', 'When a target reaches 50% slow, extra Magpies move to the next marked target.', true, PATH.sights),
	kill_confirm = {
		name = 'When a target dies early', type = 'radioButton', value = 'next', path = PATH.sights,
		items = {
			{key = 'next', name = 'Next marked target, else home'},
			{key = 'home', name = 'Go home'},
			{key = 'off', name = 'Do nothing'},
		},
	},

	-- Trigger
	hold_fire = Switch('Hold fire until the target', 'Launched Magpies hold fire so they only shoot their ordered target.', true, PATH.trigger),
	release_near_target = Switch('Free fire near the target', 'Within weapon range of the target, Magpies may also shoot units next to it.', false, PATH.trigger),
	time_on_target = Switch('Arrive together', 'Wings gather at a staging point before the attack so they arrive at the same time.', true, PATH.trigger),
	staging_distance = {name = 'Staging distance', type = 'number', value = 1300, min = 700, max = 2500, step = 50, path = PATH.trigger},
	rotate_fire = Switch('Rotate fire', 'When a wing runs dry, the next chambered wing launches at the same targets.', false, PATH.trigger),

	-- Radar
	threat_map = Switch('Anti-air threat map', nil, true, PATH.radar),
	route_lines = Switch('Route lines with risk', 'Lines from wings to their targets, coloured by expected damage per Magpie.', true, PATH.radar),
	stale_intel = Switch('Shade unseen areas on routes', 'Shades parts of a route nobody on your team has seen recently.', true, PATH.radar),
	stale_seconds = {name = 'Unseen after (s)', type = 'number', value = 60, min = 10, max = 300, step = 10, path = PATH.radar},
	route_alert = Switch('Alert on new AA along a route', nil, true, PATH.radar),
	fighter_alert = Switch('Fighter alerts', nil, true, PATH.radar),
	fighter_pullback = Switch('Pull wings back from fighters', nil, false, PATH.radar),
	stockpile_watch = Switch('Estimate enemy stockpiles', 'Counts missiles an Artemis has likely built since you saw it, and shows build ETAs for anti-air under construction.', true, PATH.radar),
	stockpile_speed = {name = 'Enemy stockpile speed (%)', desc = 'Lower this if the enemy is short on metal or energy.', type = 'number', value = 100, min = 10, max = 100, step = 5, path = PATH.radar},
	stockpile_cap = {name = 'Most missiles to assume', type = 'number', value = 30, min = 1, max = 100, step = 1, path = PATH.radar},
	reload_tracking = Switch('Track long AA reloads', 'Shows when a Hacksaw or other long-reload AA that shot your Magpies is reloading.', true, PATH.radar),

	-- Ledger
	ledger_tracking = Switch('Record sorties', nil, true, PATH.ledger),
	show_ledger = Switch('Show ledger', nil, false, PATH.ledger),
	ledger_view = {
		name = 'Ledger graph', type = 'radioButton', value = 'runs', path = PATH.ledger,
		items = {
			{key = 'runs', name = 'Hit factor per run'},
			{key = 'targets', name = 'Hit factor per target type'},
		},
	},
	career_history = Switch('Career history', 'Keep a summary of every game and show the trend.', true, PATH.ledger),
	export_csv = Switch('Save sorties to file', 'Writes LuaUI/Config/Revolver/*.csv at the end of the game.', true, PATH.ledger),

	-- Grip
	sounds = Switch('Sounds', nil, true, PATH.grip),
	open_menu = {name = 'Open Revolver menu', desc = 'Switch Revolver features on and off. Also opens from the middle of the cylinder.', type = 'button', path = PATH.grip, OnChange = function() ToggleMenu() end},
	fire = {name = 'Fire', desc = 'Send chambered Magpies at the marked targets, or the enemy under the cursor.', type = 'button', path = PATH.grip, OnChange = function() Fire() end},
	mark = {name = 'Mark target', desc = 'Add the enemy under the cursor to the target list.', type = 'button', path = PATH.grip, OnChange = function() Mark() end},
	clear_marks = {name = 'Clear marks', type = 'button', path = PATH.grip, OnChange = function() ClearMarks() end},
	recall = {name = 'Recall selected', desc = 'Send the selected Magpies, or every airborne wing if none are selected, to pads.', type = 'button', path = PATH.grip, OnChange = function() Recall() end},
	select_ready = {name = 'Select chambered wings', type = 'button', path = PATH.grip, OnChange = function() SelectReady() end},
	approach = {name = 'Set approach', desc = 'Then drag on the map in the direction the next attack should fly, or click where it should come from.', type = 'button', path = PATH.grip, OnChange = function() SetApproach() end},
	pool = {name = 'Pool half-empty Magpies', type = 'button', path = PATH.grip, OnChange = function() PoolPartial() end},
	calibrate = {name = 'Calibration mode (single player)', desc = 'Keeps sending chambered wings at the enemy under the cursor and compares measured hit rates with the Magpie Manual.', type = 'button', path = PATH.grip, OnChange = function() ToggleCalibration() end},
}
for w = 1, 6 do
	local letter = string.char(64 + w)
	options['select_' .. w] = {name = 'Select wing ' .. letter, type = 'button', path = PATH.grip, OnChange = function() SelectWing(w) end}
	options['assign_' .. w] = {name = 'Assign selected to wing ' .. letter, type = 'button', path = PATH.grip, OnChange = function() AssignSelected(w) end}
end

-- What the in-game menu lists, by module.
local MENU = {
	{title = 'Cylinder', keys = {'auto_wing', 'assign_mode', 'spare_wing', 'show_hud', 'wing_labels', 'fleet_advisor'}},
	{title = 'Reload', keys = {'pad_balance', 'retreat_state'}},
	{title = 'Sights', keys = {'show_card', 'live_correction', 'allocate', 'horizon', 'auto_style', 'slow_chain', 'kill_confirm'}},
	{title = 'Trigger', keys = {'hold_fire', 'release_near_target', 'time_on_target', 'rotate_fire'}},
	{title = 'Radar', keys = {'threat_map', 'route_lines', 'stale_intel', 'route_alert', 'fighter_alert', 'fighter_pullback', 'stockpile_watch', 'reload_tracking'}},
	{title = 'Ledger', keys = {'ledger_tracking', 'show_ledger', 'ledger_view', 'career_history', 'export_csv'}},
	{title = 'Grip', keys = {'sounds'}},
}

local function Opt(name)
	return options[name].value
end

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- State

local myTeamID, myAllyTeamID
local frame = 0

local magpies = {}     -- unitID -> data
local wings = {}       -- [1..6] -> {units = {unitID = true}, count = n}
local pads = {}        -- padID -> {defID, cap, bp}
local threats = {}     -- enemy unitID -> threat data
local marks = {}       -- ordered list of enemy unitIDs
local groups = {}      -- active attack groups, groupID -> group
local runs = {}        -- ledger, in order
local runByWing = {}   -- wing -> open run for flights Revolver did not launch
local lastHit = {}     -- enemy unitID -> {run = run, frame = n}
local reloadSeen = {}  -- enemy unitID -> frame its long-reload weapon fired at us
local alerts = {}      -- {text, frame}
local alertCooldown = {}
local totals = {metalKilled = 0, metalLost = 0, rearms = 0, repairEnergy = 0, rearmEnergy = 0}
local approachPoint    -- {x, z} to come from, or {dx, dz} flight direction
local approachMode = false
local approachDrag
local menuOpen = false
local losMemory = {}   -- grid cell -> last frame the team saw it
local losSweep = 0
local LOS_CELL = 256
local calibration
local history = {}
local nextGroupID = 1
local roundRobin = 0
local exported = false
local lastClick = {wing = 0, time = -1}

for i = 1, WING_COUNT do
	wings[i] = {units = {}, count = 0, wasReady = false}
end

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- Utilities

local function Dist2D(x1, z1, x2, z2)
	local dx, dz = x1 - x2, z1 - z2
	return sqrt(dx*dx + dz*dz)
end

local function UnitDist2D(a, b)
	local ax, _, az = spGetUnitPosition(a)
	local bx, _, bz = spGetUnitPosition(b)
	if not (ax and bx) then
		return false
	end
	return Dist2D(ax, az, bx, bz)
end

local function UnitList(set)
	local list = {}
	for unitID in pairs(set) do
		list[#list + 1] = unitID
	end
	table.sort(list)
	return list
end

local function Centroid(list)
	local sx, sz, n = 0, 0, 0
	for i = 1, #list do
		local x, _, z = spGetUnitPosition(list[i])
		if x then
			sx, sz, n = sx + x, sz + z, n + 1
		end
	end
	if n == 0 then
		return false
	end
	return sx/n, sz/n
end

local function Alert(text, key, sound)
	if key then
		if alertCooldown[key] and frame - alertCooldown[key] < 300 then
			return
		end
		alertCooldown[key] = frame
	end
	alerts[#alerts + 1] = {text = text, frame = frame}
	if #alerts > 6 then
		table.remove(alerts, 1)
	end
	Spring.Echo("Revolver: " .. text)
	if sound and Opt('sounds') then
		Spring.PlaySoundFile(sound, 1, "ui")
	end
end

local function IsAliveEnemy(unitID)
	if not (unitID and spValidUnitID(unitID)) or spGetUnitIsDead(unitID) then
		return false
	end
	local allyTeam = spGetUnitAllyTeam(unitID)
	return allyTeam ~= nil and allyTeam ~= myAllyTeamID
end

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- Magpie state

-- ammoFraction is nil both when full and when empty; noammo says which.
local function ReadAmmo(unitID)
	local noAmmo = spGetUnitRulesParam(unitID, "noammo") or 0
	if noAmmo == 1 or noAmmo == 2 then
		return 0, noAmmo
	end
	return spGetUnitRulesParam(unitID, "ammoFraction") or 1, noAmmo
end

local function ClassifyState(mag)
	if mag.noAmmo == 2 then
		return "rearming"
	elseif mag.noAmmo == 3 then
		return "repairing"
	elseif mag.noAmmo == 1 then
		return "returning"
	end
	if mag.group then
		return "attacking"
	end
	local cmdID = spGetUnitCurrentCommand(mag.unitID)
	if cmdID == CMD_REARM or cmdID == CMD_FIND_PAD then
		return "returning"
	elseif cmdID == CMD_ATTACK or cmdID == CMD_SET_TARGET or cmdID == CMD.FIGHT or cmdID == CMD.AREA_ATTACK then
		return "attacking"
	end
	return "idle"
end

local function MagpieReady(mag)
	return mag.state == "idle" and not mag.group and
		mag.ammo*100 >= Opt('ready_ammo') and (mag.health/mag.maxHealth)*100 >= Opt('ready_health')
end

local function WingSummary(w)
	local wing = wings[w]
	local ammo, health, n, ready, airborne = 0, 0, 0, 0, 0
	local states = {}
	for unitID in pairs(wing.units) do
		local mag = magpies[unitID]
		if mag then
			n = n + 1
			ammo = ammo + mag.ammo
			health = health + mag.health/mag.maxHealth
			states[mag.state] = (states[mag.state] or 0) + 1
			if MagpieReady(mag) then
				ready = ready + 1
			end
			if mag.state == "attacking" or mag.state == "returning" then
				airborne = airborne + 1
			end
		end
	end
	if n == 0 then
		return {n = 0, ammo = 0, health = 0, ready = 0, chambered = false, state = "empty", states = states}
	end
	ammo, health = ammo/n, health/n
	local chambered = ammo*100 >= Opt('ready_ammo') and health*100 >= Opt('ready_health') and ready > 0
	local state = "idle"
	if chambered then
		state = "ready"
	elseif (states.attacking or 0) > 0 then
		state = "attacking"
	elseif (states.returning or 0) > 0 then
		state = "returning"
	elseif (states.rearming or 0) + (states.repairing or 0) > 0 then
		state = "pad"
	end
	return {n = n, ammo = ammo, health = health, ready = ready, chambered = chambered, state = state, states = states}
end

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- Wings

local function RemoveFromWing(unitID)
	local mag = magpies[unitID]
	if mag and mag.wing then
		local wing = wings[mag.wing]
		if wing.units[unitID] then
			wing.units[unitID] = nil
			wing.count = wing.count - 1
		end
		mag.wing = nil
	end
end

local function AddToWing(unitID, w)
	RemoveFromWing(unitID)
	local mag = magpies[unitID]
	wings[w].units[unitID] = true
	wings[w].count = wings[w].count + 1
	mag.wing = w
	local retreat = Opt('retreat_state')
	if retreat ~= 'keep' and CMD_RETREAT then
		spGiveOrderToUnit(unitID, CMD_RETREAT, {tonumber(retreat)}, 0)
	end
end

local function PickWing()
	local cap = Opt('wing_size')
	local last = Opt('spare_wing') and WING_COUNT - 1 or WING_COUNT
	if Opt('assign_mode') == 'round' then
		for _ = 1, last do
			roundRobin = roundRobin % last + 1
			if wings[roundRobin].count < cap then
				return roundRobin
			end
		end
	else
		for w = 1, last do
			if wings[w].count < cap then
				return w
			end
		end
	end
	-- Every wing is full: put it in the smallest.
	local best, bestCount = 1, math.huge
	for w = 1, last do
		if wings[w].count < bestCount then
			best, bestCount = w, wings[w].count
		end
	end
	return best
end

local function AddMagpie(unitID)
	if magpies[unitID] then
		return
	end
	local health, maxHealth = spGetUnitHealth(unitID)
	local ammo, noAmmo = ReadAmmo(unitID)
	magpies[unitID] = {
		unitID = unitID,
		health = health or magpieStats.maxHealth,
		maxHealth = maxHealth or magpieStats.maxHealth,
		ammo = ammo,
		noAmmo = noAmmo,
		state = "idle",
	}
	if Opt('auto_wing') then
		AddToWing(unitID, PickWing())
	end
end

local function RemoveMagpie(unitID, died)
	local mag = magpies[unitID]
	if not mag then
		return
	end
	if died then
		local run = mag.run
		if run then
			run.lost = run.lost + 1
		end
		totals.metalLost = totals.metalLost + magpieStats.cost
	end
	if mag.group and groups[mag.group] then
		groups[mag.group].units[unitID] = nil
	end
	RemoveFromWing(unitID)
	magpies[unitID] = nil
end

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- Breakpoints

local function BreakpointEntry(defName, mode)
	local byMode = defs.breakpoints[mode]
	return byMode and byMode[defName]
end

local function HitFactor(defName, mode)
	local entry = BreakpointEntry(defName, mode)
	return entry and entry.hit or defs.defaultHit[mode]
end

-- Fewest Magpies to kill a target type from the tables, or nil. Falls through to the next horizon if needed.
local function TableNeed(defName, mode, horizon, slowOn)
	local entry = BreakpointEntry(defName, mode)
	if not entry then
		return nil
	end
	local list = entry[slowOn == false and "noslow" or "slow"]
	local started = false
	for i = 1, #defs.passes do
		local p = defs.passes[i]
		if p >= horizon then
			started = true
		end
		if started and list[p] then
			return list[p][1], list[p][2], p
		end
	end
	return false
end

-- Bursts one Magpie gets on a target within a number of passes.
local function BurstsWithin(mode, passes)
	if passes >= 99 then
		return magpieStats.bursts
	end
	return min(magpieStats.bursts, defs.burstsPerPass[mode]*passes)
end

-- Magpies needed for one target as it stands now. Returns need, expected losses, horizon used, source.
local function Need(targetID, mode, horizon)
	local defID = spGetUnitDefID(targetID)
	local ud = defID and UnitDefs[defID]
	if not ud then
		return 1, 0, horizon, "unknown"
	end
	local health, maxHealth = spGetUnitHealth(targetID)
	health = health or ud.health
	maxHealth = maxHealth or ud.health
	local hpFrac = max(0.05, health/max(1, maxHealth))
	local armour = 1
	if not Opt('live_correction') then
		hpFrac = 1
		health = maxHealth
	elseif Spring.GetUnitArmored then
		local armored, multiple = Spring.GetUnitArmored(targetID)
		if armored then
			armour = multiple or defs.closedArmourFactor
		end
	end

	local n, lost, used = TableNeed(ud.name, mode, horizon, true)
	if n then
		return max(1, ceil(n*hpFrac/armour - 1e-9)), lost, used, "table"
	end

	-- Not in the tables: plain damage maths, ignoring the AA it might have.
	local hit = HitFactor(ud.name, mode)
	local burstsNeeded = health/(magpieStats.damagePerBurst*hit*armour)
	local perMagpie = BurstsWithin(mode, horizon)
	local need = ceil(burstsNeeded/perMagpie - 1e-9)
	if need > 40 then
		need = ceil(burstsNeeded/magpieStats.bursts - 1e-9)
		return max(1, need), 0, 99, "estimate"
	end
	return max(1, need), 0, horizon, "estimate"
end

-- Strafe or Loopback for a target type: fewest Magpies within the horizon, then fewest losses.
local function AdviseMode(defName, horizon)
	local sN, sLost, sUsed = TableNeed(defName, "strafe", horizon, true)
	local lN, lLost, lUsed = TableNeed(defName, "loopback", horizon, true)
	if not sN and not lN then
		return "strafe"
	elseif not lN then
		return "strafe"
	elseif not sN then
		return "loopback"
	end
	-- Prefer the one that keeps the horizon.
	if sUsed ~= lUsed then
		return (sUsed < lUsed) and "strafe" or "loopback"
	end
	if lN ~= sN then
		return (lN < sN) and "loopback" or "strafe"
	end
	return (lLost < sLost) and "loopback" or "strafe"
end

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- Threat map

local function AddThreat(unitID, defID)
	local def = aaDefs[defID]
	if not def then
		return false
	end
	local x, y, z = spGetUnitPosition(unitID)
	if not x then
		return false
	end
	local isNew = not threats[unitID]
	threats[unitID] = threats[unitID] or {}
	local t = threats[unitID]
	t.defID, t.x, t.y, t.z = defID, x, y, z
	t.range, t.dps, t.ttk, t.static = def.range, def.dps, def.ttk, def.static
	t.fighter = fighterDefs[defID]
	t.inLos = true
	t.lastSeen = frame

	-- Construction: watch progress to estimate when it finishes.
	local _, _, _, _, progress = spGetUnitHealth(unitID)
	progress = progress or 1
	if progress < 1 then
		if t.progress and frame > t.progressFrame and progress > t.progress then
			t.rate = (progress - t.progress)/(frame - t.progressFrame)
		end
		t.building, t.progress, t.progressFrame = true, progress, frame
	elseif t.building or isNew then
		-- Seen finishing: the stockpile count is exact. Already built when first seen: it is a lower bound.
		t.exact = (t.building == true)
		t.building, t.progress, t.rate = false, 1, nil
		t.stock0, t.t0 = 0, frame
	end
	return isNew
end

-- Frame when a structure under construction should finish, or nil if unknown.
local function FinishFrame(t)
	if not (t.building and t.rate and t.rate > 0) then
		return nil
	end
	return t.progressFrame + (1 - t.progress)/t.rate
end

-- Missiles an enemy stockpiler probably holds: count, seconds to the next one, and whether the count is exact.
local function StockEstimate(t)
	local def = aaDefs[t.defID]
	if not (def and def.stockTime) or t.building or not t.t0 then
		return nil
	end
	local period = def.stockTime*30*100/max(1, Opt('stockpile_speed'))
	local elapsed = frame - t.t0
	local stock = t.stock0 + floor(elapsed/period)
	local cap = Opt('stockpile_cap')
	if stock >= cap then
		return cap, nil, t.exact
	end
	return stock, (period - elapsed % period)/30, t.exact
end

-- A stockpiler fired: one missile fewer, keeping progress on the next.
local function ConsumeMissile(t)
	if t.lastShot and frame - t.lastShot < 30 then
		return -- several hits from one missile
	end
	t.lastShot = frame
	local def = aaDefs[t.defID]
	local stock = StockEstimate(t)
	if not stock then
		return
	end
	local period = def.stockTime*30*100/max(1, Opt('stockpile_speed'))
	if stock > 0 then
		t.stock0 = stock - 1
		t.t0 = frame - (frame - t.t0) % period
	else
		-- It had one we did not count: restart from now.
		t.stock0, t.t0 = 0, frame
	end
end

-- Map label for a threat: missiles and next ETA for stockpilers, ETA for construction.
local function ThreatLabel(t)
	local def = aaDefs[t.defID]
	if t.building then
		local finish = FinishFrame(t)
		if finish then
			return string.format("%s %d%%, done in %ds", def.name, floor(t.progress*100), max(0, ceil((finish - frame)/30)))
		end
		return string.format("%s %d%% built", def.name, floor(t.progress*100))
	end
	local stock, nextIn, exact = StockEstimate(t)
	if stock then
		local count = (exact and "" or "at least ") .. stock .. (stock == 1 and " missile" or " missiles")
		if nextIn then
			return string.format("%s: %s, next in %ds", def.name, count, ceil(nextIn))
		end
		return def.name .. ": " .. count
	end
	return nil
end

-- Stockpiled missiles that can reach a point: total and whether every count is exact.
local function MissilesCovering(x, z)
	local total, exact, n = 0, true, 0
	for _, t in pairs(threats) do
		if aaDefs[t.defID].stockTime and Dist2D(x, z, t.x, t.z) <= t.range then
			local stock, _, isExact = StockEstimate(t)
			if stock then
				total, n = total + stock, n + 1
				exact = exact and isExact
			end
		end
	end
	return total, exact, n
end

-- Expected damage to one Magpie flying a straight line through known AA.
local function RouteRisk(x1, z1, x2, z2)
	local length = Dist2D(x1, z1, x2, z2)
	local steps = max(1, ceil(length/50))
	local dt = (length/steps)/magpieStats.speed
	local damage = 0
	local missiles = {}
	for i = 0, steps do
		local f = i/steps
		local x, z = x1 + (x2 - x1)*f, z1 + (z2 - z1)*f
		for unitID, t in pairs(threats) do
			if not t.fighter and not t.building and Dist2D(x, z, t.x, t.z) <= t.range then
				damage = damage + t.dps*dt
				if aaDefs[t.defID].stockTime and not missiles[unitID] then
					missiles[unitID] = true
					local stock = StockEstimate(t) or 0
					damage = damage + min(stock, 1)*aaDefs[t.defID].stockShot
				end
			end
		end
	end
	return damage
end

local function DistToSegment(px, pz, x1, z1, x2, z2)
	local dx, dz = x2 - x1, z2 - z1
	local len2 = dx*dx + dz*dz
	local f = 0
	if len2 > 0 then
		f = max(0, min(1, ((px - x1)*dx + (pz - z1)*dz)/len2))
	end
	return Dist2D(px, pz, x1 + dx*f, z1 + dz*f)
end

-- Line-of-sight memory: when the team last saw each map cell.
local function CellKey(x, z)
	return floor(x/LOS_CELL) .. ":" .. floor(z/LOS_CELL)
end

local function CellAge(x, z)
	if spIsPosInLos(x, spGetGroundHeight(x, z) or 0, z, myAllyTeamID) then
		losMemory[CellKey(x, z)] = frame
		return 0
	end
	local seen = losMemory[CellKey(x, z)]
	return seen and (frame - seen)/30 or math.huge
end

-- Checks a slice of the map each call so the memory covers everything over time.
local function SweepLos(count)
	local cols, rows = ceil((Game.mapSizeX or 0)/LOS_CELL), ceil((Game.mapSizeZ or 0)/LOS_CELL)
	local total = cols*rows
	for _ = 1, min(count, total) do
		losSweep = losSweep % total
		CellAge((losSweep % cols + 0.5)*LOS_CELL, (floor(losSweep/cols) + 0.5)*LOS_CELL)
		losSweep = losSweep + 1
	end
end

-- Cells in a corridor one cell either side of a route that nobody has seen recently.
local function StaleCells(x1, z1, x2, z2, maxAge)
	local out, done = {}, {}
	local length = Dist2D(x1, z1, x2, z2)
	local steps = max(1, ceil(length/(LOS_CELL*0.5)))
	local nx, nz = 0, 0
	if length > 0 then
		nx, nz = -(z2 - z1)/length, (x2 - x1)/length
	end
	for i = 0, steps do
		local f = i/steps
		for off = -1, 1 do
			local x = x1 + (x2 - x1)*f + nx*off*LOS_CELL
			local z = z1 + (z2 - z1)*f + nz*off*LOS_CELL
			local key = CellKey(x, z)
			if not done[key] then
				done[key] = true
				local age = CellAge(x, z)
				if age > maxAge then
					out[#out + 1] = {x = (floor(x/LOS_CELL) + 0.5)*LOS_CELL, z = (floor(z/LOS_CELL) + 0.5)*LOS_CELL, age = age}
				end
			end
		end
	end
	return out
end

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- Pads

local function PadHealRate(pad)
	return pad.bp*magpieStats.maxHealth/(repairCostFactor*magpieStats.cost)
end

local function RepairSeconds(mag, pad)
	local missing = max(0, mag.maxHealth - mag.health)
	return missing/PadHealRate(pad or {bp = 2.5})
end

local function PadLoad(padID)
	local n = 0
	for _, mag in pairs(magpies) do
		if mag.pad == padID and mag.noAmmo ~= 0 then
			n = n + 1
		end
	end
	return n
end

local function PadUsable(padID)
	return spGetUnitRulesParam(padID, "padExcluded" .. myTeamID) ~= 1
end

-- Pick the pad with the shortest flight plus wait.
local function ChoosePad(unitID)
	local x, _, z = spGetUnitPosition(unitID)
	if not x then
		return nil
	end
	local mag = magpies[unitID]
	local best, bestScore
	for padID, pad in pairs(pads) do
		if PadUsable(padID) then
			local px, _, pz = spGetUnitPosition(padID)
			if px then
				local flight = Dist2D(x, z, px, pz)/magpieStats.speed
				local service = magpieStats.rearmSeconds + RepairSeconds(mag, pad)
				local wait = floor(PadLoad(padID)/pad.cap)*service
				local score = flight + wait
				if not bestScore or score < bestScore then
					best, bestScore = padID, score
				end
			end
		end
	end
	return best, bestScore
end

local function ReadyETA(mag)
	if mag.state == "idle" and MagpieReady(mag) then
		return 0
	end
	local pad = mag.pad and pads[mag.pad]
	local eta = 0
	if mag.noAmmo == 1 then
		local padID = mag.pad
		if padID then
			local d = UnitDist2D(mag.unitID, padID)
			eta = eta + (d or 0)/magpieStats.speed + floor(PadLoad(padID)/pads[padID].cap)*magpieStats.rearmSeconds
		end
		eta = eta + magpieStats.rearmSeconds
	elseif mag.noAmmo == 2 then
		eta = eta + magpieStats.rearmSeconds*0.5
	end
	if mag.noAmmo ~= 0 then
		local target = mag.maxHealth*Opt('ready_health')/100
		if mag.health < target then
			eta = eta + (target - mag.health)/PadHealRate(pad or {bp = 2.5})
		end
	end
	return eta
end

local function WingETA(w)
	local worst = 0
	for unitID in pairs(wings[w].units) do
		local mag = magpies[unitID]
		if mag then
			worst = max(worst, ReadyETA(mag))
		end
	end
	return worst
end

-- Pad slots needed so a fleet cycling sorties of `cycle` seconds never waits.
local function PadPlan()
	local slots, repairBp, n, service = 0, 0, 0, 0
	for _, pad in pairs(pads) do
		slots = slots + pad.cap
	end
	for _, mag in pairs(magpies) do
		n = n + 1
		service = service + magpieStats.rearmSeconds + RepairSeconds(mag, {bp = 2.5})*0.5
	end
	if n == 0 then
		return {slots = slots, fleet = 0, need = 0, service = 0, energy = 0}
	end
	service = service/n
	local cycle = (magpieStats.bursts - 1)*0.8 + 30 -- firing time plus a typical round trip
	local need = ceil(n*service/(cycle + service))
	return {slots = slots, fleet = n, need = need, service = service, energy = need*(10 + 2.5)}
end

local airpadDef = UnitDefNames.staticrearm and padDefs[UnitDefNames.staticrearm.id]

local function FleetAdvice()
	local plan = PadPlan()
	local byType, names = {}, {}
	for _, pad in pairs(pads) do
		local name = UnitDefs[pad.defID].humanName or UnitDefs[pad.defID].name
		if not byType[name] then
			names[#names + 1] = name
		end
		byType[name] = (byType[name] or 0) + pad.cap
	end
	table.sort(names)
	local parts = {}
	for i = 1, #names do
		parts[#parts + 1] = names[i] .. " " .. byType[names[i]]
	end
	local lines = {
		string.format("Fleet %d Magpies, %d pad slots, about %d needed", plan.fleet, plan.slots, plan.need),
		string.format("Pad turnaround %.0f s each (%d s rearm plus repair)", plan.service, magpieStats.rearmSeconds),
	}
	if plan.need > plan.slots then
		local cap = airpadDef and airpadDef.cap or 4
		lines[#lines + 1] = string.format("Short %d slots: build %d more Airpad%s", plan.need - plan.slots,
			ceil((plan.need - plan.slots)/cap), ceil((plan.need - plan.slots)/cap) == 1 and "" or "s")
	else
		lines[#lines + 1] = "Pads keep up with the fleet."
	end
	lines[#lines + 1] = string.format("Energy with every needed slot busy: about %d E/s", floor(plan.energy))
	if #parts > 0 then
		lines[#lines + 1] = "Slots: " .. table.concat(parts, ", ")
	end
	return lines, plan
end

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- Ledger

local function NewRun(w, targets, mode, launched)
	local run = {
		id = #runs + 1, wing = w, start = frame, last = frame,
		targets = {}, mode = mode or "?", launched = launched,
		magpies = 0, bursts = 0, wasted = 0, landingWaste = 0,
		damage = 0, kills = 0, killValue = 0, lost = 0, open = true,
	}
	for i = 1, #(targets or {}) do
		local defID = spGetUnitDefID(targets[i])
		run.targets[#run.targets + 1] = defID and UnitDefs[defID].name or "unknown"
	end
	runs[#runs + 1] = run
	return run
end

local function RunHitFactor(run)
	if run.bursts == 0 then
		return nil
	end
	return run.damage/(run.bursts*magpieStats.damagePerBurst)
end

local function ExpectedHitFactor(run)
	local total, n = 0, 0
	for i = 1, #run.targets do
		local mode = (run.mode == "loopback") and "loopback" or "strafe"
		total = total + HitFactor(run.targets[i], mode)
		n = n + 1
	end
	if n == 0 then
		return nil
	end
	return total/n
end

local function MagpieMode(unitID)
	if not CMD_LOOP_ATTACK then
		return "?"
	end
	local index = Spring.FindUnitCmdDesc(unitID, CMD_LOOP_ATTACK)
	local descs = index and Spring.GetUnitCmdDescs(unitID, index, index)
	local desc = descs and descs[1]
	if desc and desc.params then
		return (tonumber(desc.params[1]) == 1) and "loopback" or "strafe"
	end
	return "?"
end

local function CurrentTarget(unitID)
	local cmdID, _, _, p1, p2 = spGetUnitCurrentCommand(unitID)
	if cmdID == CMD_ATTACK and p1 and not p2 then
		return p1
	end
	return nil
end

-- Called when a Magpie's ammo drops by one burst.
local function RecordBurst(mag)
	if not Opt('ledger_tracking') then
		return
	end
	local run = mag.run
	if not run or not run.open then
		local w = mag.wing or 0
		run = runByWing[w]
		if not (run and run.open and frame - run.last < 30*20) then
			local target = CurrentTarget(mag.unitID)
			run = NewRun(w, target and {target} or {}, MagpieMode(mag.unitID), false)
			runByWing[w] = run
		end
		run.magpies = run.magpies + 1
		mag.run = run
	end
	run.bursts = run.bursts + 1
	run.last = frame
	local target = (mag.group and groups[mag.group] and groups[mag.group].target) or CurrentTarget(mag.unitID)
	if target then
		local d = UnitDist2D(mag.unitID, target)
		if d and d > magpieStats.range + 100 then
			run.wasted = run.wasted + 1
		end
	else
		run.wasted = run.wasted + 1
	end
end

local function CloseRuns()
	for i = 1, #runs do
		local run = runs[i]
		if run.open then
			local active = false
			for _, mag in pairs(magpies) do
				if mag.run == run and mag.ammo > 0 and mag.noAmmo == 0 then
					active = true
					break
				end
			end
			if (not active and frame - run.last > 30*3) or frame - run.last > 30*90 then
				run.open = false
				run.stop = run.last
			end
		end
	end
end

local function CSVLine(run)
	local hit = RunHitFactor(run)
	local expected = ExpectedHitFactor(run)
	return table.concat({
		run.id, WING_LETTER[run.wing] or "-", string.format("%.1f", run.start/30), string.format("%.1f", (run.stop or run.last)/30),
		table.concat(run.targets, "|"), run.mode, run.launched and 1 or 0, run.magpies, run.bursts, run.wasted, run.landingWaste,
		string.format("%.1f", run.damage), hit and string.format("%.3f", hit) or "", expected and string.format("%.3f", expected) or "",
		run.kills, run.killValue, run.lost,
	}, ",")
end

local CSV_HEADER = "run,wing,start_s,end_s,targets,mode,launched,magpies,bursts,wasted_bursts,landing_waste,damage,hit_factor,sim_hit_factor,kills,kill_metal,magpies_lost"
local HISTORY_HEADER = "date,runs,bursts,damage,hit_factor,kills,kill_metal,magpies_lost,metal_lost"
local EXPORT_DIR = "LuaUI/Config/Revolver/"

local function GameTotals()
	local bursts, damage, kills, lost = 0, 0, 0, 0
	for i = 1, #runs do
		local run = runs[i]
		bursts, damage, kills, lost = bursts + run.bursts, damage + run.damage, kills + run.kills, lost + run.lost
	end
	local hit = (bursts > 0) and damage/(bursts*magpieStats.damagePerBurst) or nil
	return {runs = #runs, bursts = bursts, damage = damage, kills = kills, lost = lost, hit = hit}
end

local function LoadHistory()
	history = {}
	if not Opt('career_history') then
		return
	end
	local file = io.open(EXPORT_DIR .. "history.csv", "r")
	if not file then
		return
	end
	for line in file:lines() do
		local cells = {}
		for cell in (line .. ","):gmatch("([^,]*),") do
			cells[#cells + 1] = cell
		end
		local hit = tonumber(cells[5])
		if hit then
			history[#history + 1] = {date = cells[1], hit = hit, kills = tonumber(cells[6]) or 0, lost = tonumber(cells[8]) or 0}
		end
	end
	file:close()
end

local function Export()
	if exported or not Opt('export_csv') or #runs == 0 then
		return false
	end
	exported = true
	Spring.CreateDir(EXPORT_DIR)
	local stamp = os.date("%Y%m%d_%H%M%S")
	local file = io.open(EXPORT_DIR .. "sorties_" .. stamp .. ".csv", "w")
	if not file then
		return false
	end
	file:write(CSV_HEADER .. "\n")
	for i = 1, #runs do
		file:write(CSVLine(runs[i]) .. "\n")
	end
	file:close()

	local t = GameTotals()
	local newHistory = not io.open(EXPORT_DIR .. "history.csv", "r")
	local hist = Opt('career_history') and io.open(EXPORT_DIR .. "history.csv", "a")
	if hist then
		if newHistory then
			hist:write(HISTORY_HEADER .. "\n")
		end
		hist:write(table.concat({
			os.date("%Y-%m-%d %H:%M"), t.runs, t.bursts, string.format("%.1f", t.damage),
			t.hit and string.format("%.3f", t.hit) or "", t.kills, totals.metalKilled, t.lost, totals.metalLost
		}, ",") .. "\n")
		hist:close()
	end
	return EXPORT_DIR .. "sorties_" .. stamp .. ".csv"
end

-- Measured hit factor per target type and mode, against the Magpie Manual figure.
local function TargetTable()
	local agg = {}
	for i = 1, #runs do
		local run = runs[i]
		if #run.targets == 1 and run.bursts > 0 and (run.mode == "strafe" or run.mode == "loopback") then
			local key = run.targets[1] .. "/" .. run.mode
			agg[key] = agg[key] or {target = run.targets[1], mode = run.mode, bursts = 0, damage = 0, runs = 0}
			local a = agg[key]
			a.bursts, a.damage, a.runs = a.bursts + run.bursts, a.damage + run.damage, a.runs + 1
		end
	end
	local list = {}
	for _, a in pairs(agg) do
		a.measured = a.damage/(a.bursts*magpieStats.damagePerBurst)
		a.expected = HitFactor(a.target, a.mode)
		list[#list + 1] = a
	end
	table.sort(list, function(a, b)
		if a.runs ~= b.runs then
			return a.runs > b.runs
		end
		return a.target .. a.mode < b.target .. b.mode
	end)
	return list
end
local CalibrationTable = TargetTable

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- Orders

local function SetFireState(list, state)
	if #list > 0 then
		spGiveOrderToUnitArray(list, CMD_FIRE_STATE, {state}, 0)
	end
end

local function SetMode(list, mode)
	if CMD_LOOP_ATTACK and #list > 0 then
		spGiveOrderToUnitArray(list, CMD_LOOP_ATTACK, {(mode == "loopback") and 1 or 0}, 0)
	end
end

local function StagingPoint(group)
	local tx, _, tz = spGetUnitPosition(group.target)
	if not tx then
		return false
	end
	local fromX, fromZ
	local tx0, tz0 = tx, tz
	if group.approach and group.approach.dx then
		fromX, fromZ = tx0 - group.approach.dx, tz0 - group.approach.dz
	elseif group.approach then
		fromX, fromZ = group.approach.x, group.approach.z
	else
		fromX, fromZ = Centroid(UnitList(group.units))
	end
	if not fromX then
		return false
	end
	local dx, dz = fromX - tx, fromZ - tz
	local d = sqrt(dx*dx + dz*dz)
	if d < 1 then
		dx, dz, d = 0, 1, 1
	end
	local dist = Opt('staging_distance')
	local sx, sz = tx + dx/d*dist, tz + dz/d*dist
	local sy = spGetGroundHeight(sx, sz) or 0
	return sx, sy, sz
end

local function OrderAttack(group)
	local list = UnitList(group.units)
	if #list == 0 then
		return
	end
	spGiveOrderToUnitArray(list, CMD_ATTACK, {group.target}, 0)
	group.phase = "attack"
end

local function ReleaseGroup(group, home)
	local list = UnitList(group.units)
	for i = 1, #list do
		local mag = magpies[list[i]]
		if mag then
			mag.group = nil
			if mag.savedFire ~= nil then
				spGiveOrderToUnit(list[i], CMD_FIRE_STATE, {mag.savedFire}, 0)
				mag.savedFire = nil
			end
		end
	end
	if home and #list > 0 then
		spGiveOrderToUnitArray(list, CMD_FIND_PAD, {}, 0)
	end
	groups[group.id] = nil
end

local function NextTarget(group)
	local queue = group.queue or {}
	for i = 1, #queue do
		local t = queue[i]
		if t ~= group.target and IsAliveEnemy(t) then
			return t
		end
	end
	return nil
end

local function Retarget(group, target)
	group.target = target
	group.slowChained = false
	local defID = spGetUnitDefID(target)
	if Opt('auto_style') and defID then
		group.mode = AdviseMode(UnitDefs[defID].name, tonumber(Opt('horizon')))
		SetMode(UnitList(group.units), group.mode)
	end
	OrderAttack(group)
end

local function LaunchGroup(list, target, queue, mode, approach, rotate, direct)
	local group = {
		id = nextGroupID, units = {}, target = target, queue = queue, mode = mode,
		approach = approach, rotate = rotate, launchFrame = frame,
	}
	nextGroupID = nextGroupID + 1
	local w
	for i = 1, #list do
		local mag = magpies[list[i]]
		group.units[list[i]] = true
		mag.group = group.id
		mag.state = "attacking"
		w = w or mag.wing
		if Opt('hold_fire') then
			if mag.savedFire == nil then
				local firestate = spGetUnitStates(list[i], false)
				mag.savedFire = firestate or FIRESTATE_FREE
			end
		end
	end
	group.wing = w
	groups[group.id] = group

	local run = NewRun(w, {target}, mode, true)
	run.magpies = #list
	for i = 1, #list do
		magpies[list[i]].run = run
	end
	group.run = run

	SetMode(list, mode)
	if Opt('hold_fire') then
		SetFireState(list, FIRESTATE_HOLD)
	end
	if not direct and (Opt('time_on_target') or approach) then
		local sx, sy, sz = StagingPoint(group)
		if sx then
			spGiveOrderToUnitArray(list, CMD_MOVE, {sx, sy, sz}, 0)
			group.phase = "staging"
			group.staging = {sx, sy, sz}
			if not Opt('time_on_target') then
				-- Approach only: queue the attack straight after the waypoint.
				spGiveOrderToUnitArray(list, CMD_ATTACK, {target}, CMD_OPT_SHIFT)
				group.phase = "attack"
			end
			return group
		end
	end
	OrderAttack(group)
	return group
end

-- Ready Magpies, wing by wing, most ready wing first.
local function ReadyPool()
	local wingOrder = {}
	for w = 1, WING_COUNT do
		local s = WingSummary(w)
		if s.ready > 0 and not (Opt('spare_wing') and w == WING_COUNT) then
			wingOrder[#wingOrder + 1] = {w = w, s = s}
		end
	end
	table.sort(wingOrder, function(a, b)
		if a.s.chambered ~= b.s.chambered then
			return a.s.chambered
		end
		return a.w < b.w
	end)
	local pool = {}
	for i = 1, #wingOrder do
		local list = UnitList(wings[wingOrder[i].w].units)
		for j = 1, #list do
			local mag = magpies[list[j]]
			if mag and MagpieReady(mag) and not mag.group then
				pool[#pool + 1] = list[j]
			end
		end
	end
	return pool
end

-- Split ready Magpies across targets to meet each breakpoint. Pure planning: returns the plan.
local function Allocate(targets, pool, horizon)
	local plan, used = {}, 0
	local shortfall = 0
	for i = 1, #targets do
		local target = targets[i]
		local defID = spGetUnitDefID(target)
		local name = defID and UnitDefs[defID].name or "unknown"
		local mode = Opt('auto_style') and AdviseMode(name, horizon) or "strafe"
		local need, lost, usedHorizon, source = Need(target, mode, horizon)
		local take = min(need, #pool - used)
		local list = {}
		for j = used + 1, used + take do
			list[#list + 1] = pool[j]
		end
		used = used + take
		shortfall = shortfall + (need - take)
		plan[#plan + 1] = {target = target, name = name, mode = mode, need = need, lost = lost, horizon = usedHorizon, source = source, units = list}
	end
	return plan, #pool - used, shortfall
end

-- Allocation switched off: one whole chambered wing per target, in wing order.
local function WholeWings(targets, pool, horizon)
	local byWing, order = {}, {}
	for i = 1, #pool do
		local w = magpies[pool[i]].wing or 0
		if not byWing[w] then
			byWing[w] = {}
			order[#order + 1] = w
		end
		byWing[w][#byWing[w] + 1] = pool[i]
	end
	local plan, used = {}, 0
	for i = 1, #targets do
		local defID = spGetUnitDefID(targets[i])
		local name = defID and UnitDefs[defID].name or "unknown"
		local mode = Opt('auto_style') and AdviseMode(name, horizon) or "strafe"
		local list = order[i] and byWing[order[i]] or {}
		used = used + #list
		plan[#plan + 1] = {target = targets[i], name = name, mode = mode, need = #list, lost = 0, horizon = horizon, source = "wing", units = list}
	end
	return plan, #pool - used, 0
end

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- Actions

local function HoveredEnemy()
	local mx, my = spGetMouseState()
	local kind, id = spTraceScreenRay(mx, my)
	if kind == "unit" and IsAliveEnemy(id) and spGetUnitDefID(id) then
		return id
	end
	return nil
end

local function HoveredGround()
	local mx, my = spGetMouseState()
	local kind, pos = spTraceScreenRay(mx, my, true)
	if kind == "ground" then
		return pos
	end
	return nil
end

function Mark()
	local target = HoveredEnemy()
	if not target then
		return false
	end
	for i = 1, #marks do
		if marks[i] == target then
			return false
		end
	end
	marks[#marks + 1] = target
	return true
end

function ClearMarks()
	marks = {}
end

function Fire(targetsOverride, rotate)
	local targets = targetsOverride
	if not targets then
		local live = {}
		for i = 1, #marks do
			if IsAliveEnemy(marks[i]) then
				live[#live + 1] = marks[i]
			end
		end
		targets = live
		if #targets == 0 then
			local hovered = HoveredEnemy()
			targets = hovered and {hovered} or {}
		end
	end
	if #targets == 0 then
		Alert("Hover an enemy or mark targets first.")
		return false
	end
	local pool = ReadyPool()
	if #pool == 0 then
		Alert("No chambered Magpies.")
		return false
	end
	local horizon = tonumber(Opt('horizon'))
	local plan, spare, shortfall
	if Opt('allocate') then
		plan, spare, shortfall = Allocate(targets, pool, horizon)
	else
		plan, spare, shortfall = WholeWings(targets, pool, horizon)
	end
	local launched = {}
	for i = 1, #plan do
		local p = plan[i]
		if #p.units > 0 then
			launched[#launched + 1] = LaunchGroup(p.units, p.target, targets, p.mode, approachPoint, rotate or Opt('rotate_fire'))
		end
	end
	approachPoint = nil
	if shortfall > 0 then
		Alert("Short " .. shortfall .. " Magpies for the chosen kill time.")
	end
	if not targetsOverride then
		marks = {}
	end
	return launched, plan, spare
end

function Recall()
	local list = {}
	local selected = Spring.GetSelectedUnits()
	for i = 1, #selected do
		if magpies[selected[i]] then
			list[#list + 1] = selected[i]
		end
	end
	if #list == 0 then
		for unitID, mag in pairs(magpies) do
			if mag.state == "attacking" or mag.state == "idle" and mag.ammo < 1 then
				list[#list + 1] = unitID
			end
		end
	end
	for i = 1, #list do
		local mag = magpies[list[i]]
		if mag.group and groups[mag.group] then
			groups[mag.group].units[list[i]] = nil
		end
		mag.group = nil
		mag.state = "returning"
		if mag.savedFire ~= nil then
			spGiveOrderToUnit(list[i], CMD_FIRE_STATE, {mag.savedFire}, 0)
			mag.savedFire = nil
		end
	end
	if #list > 0 then
		spGiveOrderToUnitArray(list, CMD_FIND_PAD, {}, 0)
	end
	return list
end

function SelectWing(w)
	local list = UnitList(wings[w].units)
	Spring.SelectUnitArray(list)
	return list
end

function SelectReady()
	local list = {}
	for w = 1, WING_COUNT do
		if WingSummary(w).chambered then
			local units = UnitList(wings[w].units)
			for i = 1, #units do
				list[#list + 1] = units[i]
			end
		end
	end
	Spring.SelectUnitArray(list)
	return list
end

function SetApproach()
	approachMode = true
	approachDrag = nil
	Alert("Drag on the map in the direction to attack, or click where to come from. Right-click cancels.")
	return true
end

function PoolPartial()
	local moved = 0
	local cap = Opt('wing_size')
	for unitID, mag in pairs(magpies) do
		if mag.wing ~= WING_COUNT and not mag.group and mag.ammo > 0 and mag.ammo < 0.5 and mag.state == "idle" then
			if wings[WING_COUNT].count < cap*2 then
				AddToWing(unitID, WING_COUNT)
				moved = moved + 1
			end
		end
	end
	return moved
end

function ToggleCalibration()
	if calibration then
		calibration = nil
		Alert("Calibration off.")
		return false
	end
	if not Spring.Utilities.Gametype.IsSinglePlayer() then
		Alert("Calibration mode only runs in single-player games.")
		return false
	end
	local target = HoveredEnemy()
	if not target then
		Alert("Hover the target to calibrate against.")
		return false
	end
	calibration = {target = target, defID = spGetUnitDefID(target)}
	Alert("Calibration on. Chambered wings will keep attacking this target.")
	return true
end

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- Update

local function UpdateMagpie(unitID, mag)
	local health, maxHealth = spGetUnitHealth(unitID)
	if not health then
		return
	end
	local oldHealth = mag.health
	mag.health, mag.maxHealth = health, maxHealth or mag.maxHealth

	local oldAmmo, oldNoAmmo = mag.ammo, mag.noAmmo
	local ammo, noAmmo = ReadAmmo(unitID)
	mag.ammo, mag.noAmmo = ammo, noAmmo

	-- Repair on pads costs energy in proportion to health restored.
	if noAmmo == 3 and health > oldHealth then
		totals.repairEnergy = totals.repairEnergy + (health - oldHealth)*repairCostFactor*magpieStats.cost/mag.maxHealth
	end
	if oldNoAmmo ~= 2 and noAmmo == 2 then
		totals.rearms = totals.rearms + 1
		totals.rearmEnergy = totals.rearmEnergy + 10*magpieStats.rearmSeconds
	end

	-- Bursts: at most one per poll since the reload is longer than the poll.
	local step = 1/magpieStats.bursts
	if ammo < oldAmmo - step*0.5 then
		local drop = floor((oldAmmo - ammo)/step + 0.5)
		if ammo == 0 and oldAmmo > step*1.5 then
			-- Emptied with ammo left: it landed, which wastes the rest.
			if mag.run then
				mag.run.landingWaste = mag.run.landingWaste + floor(oldAmmo/step + 0.5)
			end
		else
			for _ = 1, max(1, drop) do
				RecordBurst(mag)
			end
		end
	end

	-- Pad balancing: once per trip home.
	if noAmmo == 1 and oldNoAmmo ~= 1 then
		if mag.group and groups[mag.group] then
			groups[mag.group].units[unitID] = nil
		end
		mag.group = nil
		if mag.savedFire ~= nil then
			spGiveOrderToUnit(unitID, CMD_FIRE_STATE, {mag.savedFire}, 0)
			mag.savedFire = nil
		end
		if Opt('pad_balance') and next(pads) then
			local padID = ChoosePad(unitID)
			if padID then
				mag.pad = padID
				spGiveOrderToUnit(unitID, CMD_REARM, {padID}, 0)
			end
		end
	elseif noAmmo == 0 and oldNoAmmo ~= 0 then
		mag.pad = nil
	end
	if noAmmo ~= 0 and not mag.pad then
		local cmdID, _, _, p1 = spGetUnitCurrentCommand(unitID)
		if cmdID == CMD_REARM and p1 and pads[p1] then
			mag.pad = p1
		end
	end

	mag.state = ClassifyState(mag)
end

local function UpdateGroups()
	for id, group in pairs(groups) do
		-- Drop members that went home or died.
		for unitID in pairs(group.units) do
			local mag = magpies[unitID]
			if not mag or mag.group ~= id then
				group.units[unitID] = nil
			end
		end
		if not next(group.units) then
			groups[id] = nil
		elseif not IsAliveEnemy(group.target) then
			-- Kill confirm
			local mode = Opt('kill_confirm')
			local nextTarget = (mode == 'next') and NextTarget(group)
			if nextTarget then
				Retarget(group, nextTarget)
			elseif mode == 'off' then
				ReleaseGroup(group, false)
			else
				ReleaseGroup(group, true)
			end
		else
			local list = UnitList(group.units)
			if group.phase == "staging" then
				-- Time on target: release once most of the wing is at the staging point, or after 12 s.
				local sx, _, sz = group.staging[1], group.staging[2], group.staging[3]
				local near = 0
				for i = 1, #list do
					local x, _, z = spGetUnitPosition(list[i])
					if x and Dist2D(x, z, sx, sz) < 350 then
						near = near + 1
					end
				end
				if near >= ceil(#list*0.8) or frame - group.launchFrame > 30*12 then
					OrderAttack(group)
				end
			elseif group.phase == "attack" then
				-- Fire discipline
				if Opt('hold_fire') and Opt('release_near_target') then
					for i = 1, #list do
						local mag = magpies[list[i]]
						local d = UnitDist2D(list[i], group.target)
						local want = (d and d <= magpieStats.range + 60) and FIRESTATE_FREE or FIRESTATE_HOLD
						if mag.fireNow ~= want then
							mag.fireNow = want
							spGiveOrderToUnit(list[i], CMD_FIRE_STATE, {want}, 0)
						end
					end
				end
				-- Slow chain
				if Opt('slow_chain') and not group.slowChained and #list > 1 then
					local slow = spGetUnitRulesParam(group.target, "slowState") or 0
					if slow >= defs.maxSlow then
						local nextTarget = NextTarget(group)
						if nextTarget then
							group.slowChained = true
							local keep = ceil(#list/2)
							local moving = {}
							for i = keep + 1, #list do
								moving[#moving + 1] = list[i]
								group.units[list[i]] = nil
								magpies[list[i]].group = nil
							end
							LaunchGroup(moving, nextTarget, group.queue, group.mode, nil, group.rotate, true)
						end
					end
				end
			end
		end
	end
end

local function UpdateRotation()
	for _, group in pairs(groups) do
		if group.rotate and not group.rotated and IsAliveEnemy(group.target) then
			local ammo, n = 0, 0
			for unitID in pairs(group.units) do
				ammo, n = ammo + magpies[unitID].ammo, n + 1
			end
			if n == 0 or ammo/n < 0.15 then
				group.rotated = true
				Fire({group.target}, true)
			end
		end
	end
	if calibration then
		if not IsAliveEnemy(calibration.target) then
			calibration = nil
			Alert("Calibration target is gone. Calibration off.")
		else
			local busy = false
			for _, group in pairs(groups) do
				if group.target == calibration.target then
					busy = true
				end
			end
			if not busy and #ReadyPool() > 0 then
				Fire({calibration.target})
			end
		end
	end
end

local function UpdateThreats()
	for unitID, t in pairs(threats) do
		local defID = spValidUnitID(unitID) and spGetUnitDefID(unitID)
		if defID then
			AddThreat(unitID, defID)
		else
			t.inLos = false
			local finish = FinishFrame(t)
			if finish and frame >= finish then
				-- Out of sight but should be finished by now.
				t.building, t.progress, t.rate = false, 1, nil
				t.stock0, t.t0, t.exact = 0, floor(finish), true
				Alert(aaDefs[t.defID].name .. " under construction is probably finished.", "built" .. unitID)
			end
			if not t.static then
				if frame - t.lastSeen > 30*20 then
					threats[unitID] = nil
				end
			elseif spIsPosInLos(t.x, t.y, t.z, myAllyTeamID) and not spValidUnitID(unitID) then
				threats[unitID] = nil -- We can see the spot and it is gone.
			end
		end
	end

	-- Fighter alerts
	if Opt('fighter_alert') then
		for unitID, t in pairs(threats) do
			if t.fighter and t.inLos then
				for gid, group in pairs(groups) do
					local cx, cz = Centroid(UnitList(group.units))
					if cx and Dist2D(cx, cz, t.x, t.z) < 1400 then
						Alert("Fighters near wing " .. (WING_LETTER[group.wing] or "?") .. ".", "fighter" .. gid, "sounds/reply/alarm.wav")
						if Opt('fighter_pullback') then
							ReleaseGroup(group, true)
						end
					end
				end
			end
		end
	end
end

local function UpdateWings()
	for w = 1, WING_COUNT do
		local s = WingSummary(w)
		if s.chambered and not wings[w].wasReady then
			Alert("Wing " .. WING_LETTER[w] .. " chambered (" .. s.n .. ").", nil, "sounds/beep4.wav")
		end
		wings[w].wasReady = s.chambered
	end
	if Opt('spare_wing') then
		PoolPartial()
	end
end

-- Routes from wings to targets, with risk and unseen cells, refreshed twice a second.
local routeCache = {}

local function UpdateRoutes()
	local list = {}
	local function Add(x1, z1, target, label)
		local tx, ty, tz = spGetUnitPosition(target)
		if not (tx and x1) then
			return
		end
		local route = {x1 = x1, z1 = z1, x2 = tx, z2 = tz, y = ty, label = label}
		route.risk = RouteRisk(x1, z1, tx, tz)
		if Opt('stale_intel') then
			route.stale = StaleCells(x1, z1, tx, tz, Opt('stale_seconds'))
		end
		list[#list + 1] = route
	end
	for _, group in pairs(groups) do
		local cx, cz = Centroid(UnitList(group.units))
		Add(cx, cz, group.target, WING_LETTER[group.wing] or "?")
	end
	local readyX, readyZ = Centroid(ReadyPool())
	for i = 1, #marks do
		if IsAliveEnemy(marks[i]) then
			Add(readyX, readyZ, marks[i], tostring(i))
		end
	end
	local hovered = Opt('show_card') and HoveredEnemy()
	if hovered then
		Add(readyX, readyZ, hovered, "")
	end
	routeCache = list
end

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- Callins

local function IsMine(unitTeam)
	return unitTeam == myTeamID
end

function widget:UnitFinished(unitID, unitDefID, unitTeam)
	if not IsMine(unitTeam) then
		if padDefs[unitDefID] and Spring.AreTeamsAllied(unitTeam, myTeamID) then
			pads[unitID] = {defID = unitDefID, cap = padDefs[unitDefID].cap, bp = padDefs[unitDefID].bp}
		end
		return
	end
	if unitDefID == magpieDefID then
		AddMagpie(unitID)
	elseif padDefs[unitDefID] then
		pads[unitID] = {defID = unitDefID, cap = padDefs[unitDefID].cap, bp = padDefs[unitDefID].bp}
	end
end

function widget:UnitGiven(unitID, unitDefID, newTeam)
	if newTeam == myTeamID then
		local _, _, _, _, buildProgress = spGetUnitHealth(unitID)
		if (buildProgress or 1) >= 1 then
			widget:UnitFinished(unitID, unitDefID, newTeam)
		end
	end
end

function widget:UnitTaken(unitID, unitDefID, oldTeam, newTeam)
	if oldTeam == myTeamID and newTeam ~= myTeamID then
		RemoveMagpie(unitID, false)
	end
end

function widget:UnitDestroyed(unitID, unitDefID, unitTeam)
	if magpies[unitID] then
		RemoveMagpie(unitID, true)
		return
	end
	if pads[unitID] then
		pads[unitID] = nil
		for _, mag in pairs(magpies) do
			if mag.pad == unitID then
				mag.pad = nil
			end
		end
		return
	end
	threats[unitID] = nil
	reloadSeen[unitID] = nil
	local hit = lastHit[unitID]
	if hit and frame - hit.frame < 30*5 then
		local cost = UnitDefs[unitDefID] and UnitDefs[unitDefID].metalCost or 0
		hit.run.kills = hit.run.kills + 1
		hit.run.killValue = hit.run.killValue + cost
		totals.metalKilled = totals.metalKilled + cost
	end
	lastHit[unitID] = nil
end

function widget:UnitDamaged(unitID, unitDefID, unitTeam, damage, paralyzer, weaponDefID, projectileID, attackerID, attackerDefID, attackerTeam)
	if paralyzer or not damage then
		return
	end
	local attacker = attackerID and magpies[attackerID]
	if attacker and not Spring.AreTeamsAllied(unitTeam, myTeamID) then
		local run = attacker.run
		if run and Opt('ledger_tracking') then
			run.damage = run.damage + damage
			lastHit[unitID] = {run = run, frame = frame}
		end
		return
	end
	local shooter = attackerID and threats[attackerID]
	if shooter and aaDefs[shooter.defID].stockTime then
		ConsumeMissile(shooter)
	end
	-- Something shot one of our Magpies: note long reloads.
	if magpies[unitID] and attackerID and attackerDefID and aaDefs[attackerDefID] and aaDefs[attackerDefID].reload then
		reloadSeen[attackerID] = frame
	end
end

function widget:UnitEnteredLos(unitID, unitTeam)
	if Spring.AreTeamsAllied(unitTeam, myTeamID) then
		return
	end
	local defID = spGetUnitDefID(unitID)
	if not defID then
		return
	end
	if AddThreat(unitID, defID) then
		-- New anti-air on the route of a wing on its way in?
		local t = threats[unitID]
		for gid, group in pairs(groups) do
			local tx, _, tz = spGetUnitPosition(group.target)
			local cx, cz = Centroid(UnitList(group.units))
			if Opt('route_alert') and tx and cx and not t.fighter and DistToSegment(t.x, t.z, cx, cz, tx, tz) <= t.range then
				Alert("New " .. aaDefs[defID].name .. " on wing " .. (WING_LETTER[group.wing] or "?") .. "'s route.", "route" .. gid .. "_" .. unitID, "sounds/reply/alarm.wav")
			end
		end
	end
end

function widget:UnitLeftLos(unitID)
	local t = threats[unitID]
	if t then
		t.inLos = false
		t.lastSeen = frame
	end
end

function widget:GameFrame(n)
	frame = n
	if n % 4 == 0 then
		for unitID, mag in pairs(magpies) do
			UpdateMagpie(unitID, mag)
		end
	end
	if n % 6 == 2 then
		UpdateGroups()
	end
	if n % 15 == 11 and (Opt('route_lines') or Opt('stale_intel')) then
		UpdateRoutes()
	end
	if n % 30 == 13 and Opt('stale_intel') then
		SweepLos(64)
	end
	if n % 15 == 7 then
		UpdateThreats()
		UpdateWings()
		UpdateRotation()
		CloseRuns()
	end
end

function widget:GameOver()
	CloseRuns()
	Export()
end

local function CheckSpec()
	if Spring.GetSpectatingState() then
		widgetHandler:RemoveWidget()
		return true
	end
	return false
end

function widget:PlayerChanged()
	if CheckSpec() then
		return
	end
	myTeamID = Spring.GetMyTeamID()
	myAllyTeamID = Spring.GetMyAllyTeamID()
end

function AssignSelected(w)
	local selected = Spring.GetSelectedUnits() or {}
	local n = 0
	for i = 1, #selected do
		if magpies[selected[i]] then
			AddToWing(selected[i], w)
			n = n + 1
		end
	end
	return n
end

function ToggleMenu()
	menuOpen = not menuOpen
	return menuOpen
end

-- Change an option and keep the settings menu in step.
local function SetOption(key, value)
	local option = options[key]
	option.value = value
	if WG.SetWidgetOption then
		WG.SetWidgetOption(widget:GetInfo().name, option.path or options_path, key, value)
	end
	if key == 'career_history' and value then
		LoadHistory()
	end
end

-- Next value for a menu row: flip a switch, or step through a list.
local function NextOptionValue(key)
	local option = options[key]
	if option.type == 'bool' then
		return not option.value
	end
	local items = option.items
	for i = 1, #items do
		if items[i].key == option.value then
			return items[i % #items + 1].key
		end
	end
	return items[1].key
end

local ACTIONS = {
	revolver_fire = function() Fire() end,
	revolver_mark = function() Mark() end,
	revolver_clear = function() ClearMarks() end,
	revolver_recall = function() Recall() end,
	revolver_ready = function() SelectReady() end,
	revolver_approach = function() SetApproach() end,
	revolver_pool = function() PoolPartial() end,
	revolver_calibrate = function() ToggleCalibration() end,
	revolver_ledger = function() options.show_ledger.value = not options.show_ledger.value end,
	revolver_menu = function() ToggleMenu() end,
}

function widget:Initialize()
	if not magpieDefID then
		Spring.Echo("Revolver: no Magpie unit in this game, disabling.")
		widgetHandler:RemoveWidget()
		return
	end
	if CheckSpec() then
		return
	end
	myTeamID = Spring.GetMyTeamID()
	myAllyTeamID = Spring.GetMyAllyTeamID()
	frame = Spring.GetGameFrame()

	local units = Spring.GetTeamUnits(myTeamID) or {}
	for i = 1, #units do
		local unitID = units[i]
		local defID = spGetUnitDefID(unitID)
		local _, _, _, _, buildProgress = spGetUnitHealth(unitID)
		if (buildProgress or 1) >= 1 then
			widget:UnitFinished(unitID, defID, myTeamID)
		end
	end
	for _, teamID in ipairs(Spring.GetTeamList(myAllyTeamID) or {}) do
		if teamID ~= myTeamID then
			local allied = Spring.GetTeamUnits(teamID) or {}
			for i = 1, #allied do
				local defID = spGetUnitDefID(allied[i])
				if padDefs[defID] then
					widget:UnitFinished(allied[i], defID, teamID)
				end
			end
		end
	end

	-- Anti-air already in sight when the widget starts.
	local visible = Spring.GetAllUnits() or {}
	for i = 1, #visible do
		local teamID = Spring.GetUnitTeam(visible[i])
		if teamID and not Spring.AreTeamsAllied(teamID, myTeamID) then
			widget:UnitEnteredLos(visible[i], teamID)
		end
	end

	for name, fn in pairs(ACTIONS) do
		widgetHandler.actionHandler:AddAction(widget, name, fn, nil, "t")
	end
	for w = 1, WING_COUNT do
		widgetHandler.actionHandler:AddAction(widget, "revolver_wing_" .. w, function() SelectWing(w) end, nil, "t")
		widgetHandler.actionHandler:AddAction(widget, "revolver_assign_" .. w, function() AssignSelected(w) end, nil, "t")
	end
	LoadHistory()

	WG.Revolver = {
		GetWings = function() local out = {} for w = 1, WING_COUNT do out[w] = WingSummary(w) end return out end,
		GetRuns = function() return runs end,
		Need = Need,
		Fire = Fire,
	}
end

function widget:Shutdown()
	CloseRuns()
	Export()
	for name in pairs(ACTIONS) do
		widgetHandler.actionHandler:RemoveAction(widget, name)
	end
	for w = 1, WING_COUNT do
		widgetHandler.actionHandler:RemoveAction(widget, "revolver_wing_" .. w)
		widgetHandler.actionHandler:RemoveAction(widget, "revolver_assign_" .. w)
	end
	-- Hand fire states back.
	for unitID, mag in pairs(magpies) do
		if mag.savedFire ~= nil then
			spGiveOrderToUnit(unitID, CMD_FIRE_STATE, {mag.savedFire}, 0)
		end
	end
	WG.Revolver = nil
end

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- Drawing

local CardLines
do

local GL_LINE_STRIP, GL_TRIANGLE_FAN, GL_LINES = GL.LINE_STRIP, GL.TRIANGLE_FAN, GL.LINES

local COLOR = {
	ready     = {0.67, 0.57, 1.0, 1},
	attacking = {0.85, 0.71, 0.36, 1},
	returning = {1.0, 0.56, 0.53, 1},
	pad       = {0.65, 0.63, 0.71, 1},
	idle      = {0.65, 0.63, 0.71, 1},
	empty     = {0.4, 0.4, 0.45, 0.6},
	text      = {0.92, 0.91, 0.95, 1},
	muted     = {0.65, 0.63, 0.71, 1},
	panel     = {0.08, 0.08, 0.11, 0.78},
	ring      = {0.2, 0.2, 0.26, 0.9},
}

local function ChamberCentre(w)
	local vsx = Spring.GetViewGeometry()
	local cx, cy = vsx - hud.x, hud.y
	local angle = pi/2 - (w - 1)*pi/3
	return cx + cos(angle)*(hud.radius - hud.chamber - 4), cy + sin(angle)*(hud.radius - hud.chamber - 4), cx, cy
end

local function Circle(x, y, r, segments, fraction)
	fraction = fraction or 1
	gl.BeginEnd(GL_LINE_STRIP, function()
		local n = max(2, floor(segments*fraction))
		for i = 0, n do
			local a = pi/2 - 2*pi*fraction*i/n
			gl.Vertex(x + cos(a)*r, y + sin(a)*r)
		end
	end)
end

local function Disc(x, y, r, segments)
	gl.BeginEnd(GL_TRIANGLE_FAN, function()
		gl.Vertex(x, y)
		for i = 0, segments do
			local a = 2*pi*i/segments
			gl.Vertex(x + cos(a)*r, y + sin(a)*r)
		end
	end)
end

local function DrawCylinder()
	local _, _, cx, cy = ChamberCentre(1)
	gl.Color(COLOR.panel)
	Disc(cx, cy, hud.radius, 48)
	for w = 1, WING_COUNT do
		local x, y = ChamberCentre(w)
		local s = WingSummary(w)
		gl.Color(COLOR.ring)
		Disc(x, y, hud.chamber, 24)
		gl.LineWidth(3)
		gl.Color(COLOR.ring)
		Circle(x, y, hud.chamber - 3, 32, 1)
		if s.n > 0 then
			gl.Color(COLOR[s.state] or COLOR.idle)
			Circle(x, y, hud.chamber - 3, 32, s.ammo)
		end
		gl.LineWidth(1)
		gl.Color(COLOR.text)
		gl.Text(WING_LETTER[w], x, y + 2, 15, "cv")
		local sub
		if s.n == 0 then
			sub = "-"
		elseif s.state == "pad" or s.state == "returning" then
			sub = s.n .. " " .. ceil(WingETA(w)) .. "s"
		else
			sub = s.n .. " " .. floor(s.ammo*100 + 0.5) .. "%"
		end
		gl.Color(COLOR.muted)
		gl.Text(sub, x, y - 12, 10, "cv")
	end
	gl.Color(COLOR.muted)
	if Opt('fleet_advisor') then
		local plan = PadPlan()
		gl.Text("Pads " .. plan.slots .. " / need " .. plan.need .. "   Fleet " .. plan.fleet, cx, cy - hud.radius - 14, 11, "cv")
	end
	gl.Text("menu", cx, cy, 9, "cv")
	for i = 1, #alerts do
		local a = alerts[#alerts - i + 1]
		if frame - a.frame < 30*8 then
			gl.Text(a.text, cx, cy + hud.radius + 6 + 14*(i - 1), 11, "cv")
		end
	end
	gl.Color(1, 1, 1, 1)
end

function CardLines(target)
	local defID = spGetUnitDefID(target)
	local ud = defID and UnitDefs[defID]
	if not ud then
		return nil
	end
	local lines = {ud.humanName or ud.name}
	local entryS = BreakpointEntry(ud.name, "strafe")
	if entryS then
		local function cell(mode, p)
			local entry = BreakpointEntry(ud.name, mode)
			local v = entry and entry.slow[p]
			return v and (v[1] .. " (lose " .. v[2] .. ")") or "no"
		end
		lines[#lines + 1] = "Kill within     Strafe        Loopback"
		local labels = {[1] = "1 pass", [2] = "2 passes", [3] = "3 passes", [5] = "5 passes", [99] = "1 sortie"}
		for i = 1, #defs.passes do
			local p = defs.passes[i]
			lines[#lines + 1] = string.format("%-15s %-13s %s", labels[p], cell("strafe", p), cell("loopback", p))
		end
	end
	local horizon = tonumber(Opt('horizon'))
	local mode = AdviseMode(ud.name, horizon)
	local need, lost, used, source = Need(target, mode, horizon)
	local slow = spGetUnitRulesParam(target, "slowState") or 0
	lines[#lines + 1] = string.format("Now: %s, %d Magpies%s (%s)%s", mode == "loopback" and "Loopback" or "Strafe", need,
		(lost and lost > 0) and (", lose " .. lost) or "", source == "table" and "Magpie Manual" or "estimate",
		slow > 0.01 and string.format(", slowed %d%%", floor(slow*100)) or "")

	local tx, _, tz = spGetUnitPosition(target)
	if Opt('stockpile_watch') and tx then
		local missiles, exact, n = MissilesCovering(tx, tz)
		if n > 0 then
			lines[#lines + 1] = string.format("Covered by %d stockpiler%s: %s%d missiles ready", n, n == 1 and "" or "s",
				exact and "" or "at least ", missiles)
		end
	end
	local pool = ReadyPool()
	local cx, cz = Centroid(pool)
	if cx and tx then
		local risk = RouteRisk(cx, cz, tx, tz)
		lines[#lines + 1] = string.format("Ready: %d Magpies. Route risk %d HP per Magpie.", #pool, floor(risk))
	else
		lines[#lines + 1] = "No Magpies chambered."
	end
	return lines
end

local function DrawCard()
	local target = HoveredEnemy()
	if not target then
		return
	end
	local lines = CardLines(target)
	if not lines then
		return
	end
	local mx, my = spGetMouseState()
	local w, h = 330, 16*#lines + 10
	local x, y = mx + 24, my - 12
	gl.Color(COLOR.panel)
	gl.Rect(x, y - h, x + w, y)
	for i = 1, #lines do
		gl.Color(i == 1 and COLOR.text or COLOR.muted)
		gl.Text(lines[i], x + 8, y - 16*i, 12, "o")
	end
	gl.Color(1, 1, 1, 1)
end

local function LedgerRect()
	local _, vsy = Spring.GetViewGeometry()
	local h = ledgerPanel.h + (Opt('fleet_advisor') and 70 or 0)
	return ledgerPanel.x, vsy - ledgerPanel.y, ledgerPanel.w, h
end

local function DrawLedger()
	local x, y, w, h = LedgerRect()
	gl.Color(COLOR.panel)
	gl.Rect(x, y - h, x + w, y)
	local t = GameTotals()
	gl.Color(COLOR.text)
	local view = Opt('ledger_view')
	gl.Text("Revolver ledger", x + 8, y - 16, 13, "o")
	gl.Color(COLOR.muted)
	gl.Text(view == 'runs' and "[per run]  per target" or "per run  [per target]", x + w - 8, y - 16, 11, "ro")
	gl.Text(string.format("Runs %d  Bursts %d  Hit %s  Kills %d  Lost %d", t.runs, t.bursts,
		t.hit and string.format("%.2f", t.hit) or "-", t.kills, t.lost), x + 8, y - 32, 11, "o")
	gl.Text(string.format("Metal killed %d  lost %d  Pad energy %d", totals.metalKilled, totals.metalLost,
		floor(totals.rearmEnergy + totals.repairEnergy)), x + 8, y - 46, 11, "o")
	if #history > 0 and Opt('career_history') then
		local sum, n = 0, 0
		for i = max(1, #history - 9), #history do
			sum, n = sum + history[i].hit, n + 1
		end
		gl.Text(string.format("Last %d games: hit %.2f", n, sum/n), x + 8, y - 60, 11, "o")
	end

	local gx, gy, gw, gh = x + 30, y - ledgerPanel.h + 20, w - 40, ledgerPanel.h - 100
	if view == 'runs' then
		-- Hit factor per run, last 20, against the simulated factor.
		gl.Color(COLOR.ring)
		gl.Rect(gx, gy, gx + gw, gy + 1)
		gl.Rect(gx, gy + gh, gx + gw, gy + gh + 1)
		gl.Color(COLOR.muted)
		gl.Text("1.0", gx - 4, gy + gh, 9, "rv")
		gl.Text("0", gx - 4, gy, 9, "rv")
		local first = max(1, #runs - 19)
		local slot = gw/20
		for i = first, #runs do
			local run = runs[i]
			local hit = RunHitFactor(run)
			local px = gx + (i - first)*slot + slot*0.5
			if hit then
				gl.Color(run.mode == "loopback" and COLOR.attacking or COLOR.ready)
				gl.Rect(px - slot*0.3, gy, px + slot*0.3, gy + min(1, hit)*gh)
			end
			local expected = ExpectedHitFactor(run)
			if expected then
				gl.Color(COLOR.text)
				gl.Rect(px - slot*0.45, gy + expected*gh, px + slot*0.45, gy + expected*gh + 2)
			end
		end
	else
		-- Hit factor per target type and style: bar is measured, tick is the Magpie Manual figure.
		local list = TargetTable()
		local rows = min(6, #list)
		if rows == 0 then
			gl.Color(COLOR.muted)
			gl.Text("No single-target runs yet.", gx, gy + gh*0.5, 11, "o")
		end
		local rowH = gh/6
		local labelW = 120
		for i = 1, rows do
			local a = list[i]
			local ry = gy + gh - rowH*i
			local name = BreakpointEntry(a.target, a.mode) and BreakpointEntry(a.target, a.mode).name or a.target
			gl.Color(COLOR.muted)
			gl.Text(string.format("%s %s", name, a.mode == "loopback" and "L" or "S"), gx - 22, ry + rowH*0.3, 10, "o")
			local bx, bw = gx + labelW - 22, gw - labelW - 30
			gl.Color(a.mode == "loopback" and COLOR.attacking or COLOR.ready)
			gl.Rect(bx, ry + 2, bx + bw*min(1, a.measured), ry + rowH - 2)
			gl.Color(COLOR.text)
			gl.Rect(bx + bw*a.expected - 1, ry, bx + bw*a.expected + 1, ry + rowH)
			gl.Text(string.format("%.2f/%.2f", a.measured, a.expected), bx + bw + 4, ry + rowH*0.3, 9, "o")
		end
	end
	if calibration then
		local list = CalibrationTable()
		gl.Color(COLOR.text)
		for i = 1, min(1, #list) do
			local a = list[i]
			gl.Text(string.format("Calibrating %s %s: %.2f vs %.2f (%d runs)", a.target, a.mode, a.measured, a.expected, a.runs),
				x + 8, y - 74, 10, "o")
		end
	end
	if Opt('fleet_advisor') then
		local lines = FleetAdvice()
		gl.Color(COLOR.muted)
		for i = 1, #lines do
			gl.Text(lines[i], x + 8, y - ledgerPanel.h - 12*i + 4, 10, "o")
		end
	end
	gl.Color(1, 1, 1, 1)
end

-- In-game feature menu
local menuPanel = {w = 420, row = 18}

local function MenuLayout()
	local vsx, vsy = Spring.GetViewGeometry()
	local rows = {}
	for i = 1, #MENU do
		rows[#rows + 1] = {header = MENU[i].title}
		for j = 1, #MENU[i].keys do
			rows[#rows + 1] = {key = MENU[i].keys[j]}
		end
	end
	rows[#rows + 1] = {close = true}
	local h = #rows*menuPanel.row + 30
	local x = floor(vsx*0.5 - menuPanel.w*0.5)
	local top = floor(vsy*0.5 + h*0.5)
	for i = 1, #rows do
		rows[i].y1 = top - 26 - i*menuPanel.row
		rows[i].y2 = rows[i].y1 + menuPanel.row
	end
	return rows, x, top, menuPanel.w, h
end

local function OptionText(key)
	local option = options[key]
	if option.type == 'bool' then
		return option.value and "On" or "Off"
	end
	for i = 1, #option.items do
		if option.items[i].key == option.value then
			return option.items[i].name
		end
	end
	return tostring(option.value)
end

local function DrawMenu()
	local rows, x, top, w, h = MenuLayout()
	gl.Color(COLOR.panel)
	gl.Rect(x, top - h, x + w, top)
	gl.Color(COLOR.text)
	gl.Text("Revolver features", x + 10, top - 20, 14, "o")
	for i = 1, #rows do
		local r = rows[i]
		if r.header then
			gl.Color(COLOR.attacking)
			gl.Text(r.header, x + 10, r.y1 + 4, 12, "o")
		elseif r.close then
			gl.Color(COLOR.muted)
			gl.Text("Close", x + w*0.5, r.y1 + 4, 12, "co")
		else
			local option = options[r.key]
			local on = option.type ~= 'bool' or option.value
			gl.Color(COLOR.text)
			gl.Text(option.name, x + 24, r.y1 + 4, 11, "o")
			gl.Color(on and COLOR.ready or COLOR.muted)
			gl.Text(OptionText(r.key), x + w - 10, r.y1 + 4, 11, "ro")
		end
	end
	gl.Color(1, 1, 1, 1)
end

local function MenuClick(mx, my)
	local rows, x, top, w, h = MenuLayout()
	if mx < x or mx > x + w or my < top - h or my > top then
		return false
	end
	for i = 1, #rows do
		local r = rows[i]
		if my >= r.y1 and my < r.y2 then
			if r.close then
				menuOpen = false
			elseif r.key then
				SetOption(r.key, NextOptionValue(r.key))
			end
		end
	end
	return true
end

function widget:DrawScreen()
	if Opt('show_hud') then
		DrawCylinder()
	end
	if Opt('show_card') then
		DrawCard()
	end
	if Opt('show_ledger') then
		DrawLedger()
	end
	if menuOpen then
		DrawMenu()
	end
end

function widget:DrawWorldPreUnit()
	if Opt('threat_map') then
		gl.LineWidth(1.5)
		for unitID, t in pairs(threats) do
			if not t.fighter then
				-- Redder the faster it kills a Magpie.
				local danger = max(0, min(1, 1 - t.ttk/15))
				local stock = StockEstimate(t)
				if stock then
					danger = (stock > 0) and 1 or 0.2
				end
				local alpha = t.inLos and 0.55 or 0.25
				if t.building then
					alpha = 0.12 -- not a threat yet
				end
				gl.Color(1, 0.75 - 0.6*danger, 0.3, alpha)
				gl.DrawGroundCircle(t.x, t.y, t.z, t.range, 48)
			end
		end
	end
	if Opt('stale_intel') then
		gl.Color(0.55, 0.55, 0.62, 0.35)
		for i = 1, #routeCache do
			local stale = routeCache[i].stale or {}
			for j = 1, #stale do
				local c = stale[j]
				gl.DrawGroundCircle(c.x, spGetGroundHeight(c.x, c.z) or 0, c.z, LOS_CELL*0.45, 12)
			end
		end
	end
	if Opt('route_lines') then
		gl.LineWidth(2)
		for i = 1, #routeCache do
			local r = routeCache[i]
			-- Green when safe, red when the route alone would kill a Magpie.
			local danger = max(0, min(1, r.risk/magpieStats.maxHealth))
			gl.Color(0.3 + 0.7*danger, 0.9 - 0.7*danger, 0.35, 0.8)
			gl.BeginEnd(GL_LINES, function()
				gl.Vertex(r.x1, (spGetGroundHeight(r.x1, r.z1) or 0) + 40, r.z1)
				gl.Vertex(r.x2, r.y + 40, r.z2)
			end)
		end
	end
	if approachDrag then
		gl.LineWidth(3)
		gl.Color(COLOR.ready)
		gl.BeginEnd(GL_LINES, function()
			gl.Vertex(approachDrag[1], (spGetGroundHeight(approachDrag[1], approachDrag[2]) or 0) + 20, approachDrag[2])
			gl.Vertex(approachDrag[3], (spGetGroundHeight(approachDrag[3], approachDrag[4]) or 0) + 20, approachDrag[4])
		end)
	end
	gl.Color(COLOR.attacking)
	for i = 1, #marks do
		local x, y, z = spGetUnitPosition(marks[i])
		if x then
			gl.DrawGroundCircle(x, y, z, 60, 20)
		end
	end
	gl.LineWidth(1)
	gl.Color(1, 1, 1, 1)
end

function widget:DrawWorld()
	-- Wing letters over airborne wings, mark numbers, reload timers, route risk.
	if Opt('route_lines') then
		for i = 1, #routeCache do
			local r = routeCache[i]
			gl.PushMatrix()
			gl.Translate((r.x1 + r.x2)*0.5, (r.y or 0) + 60, (r.z1 + r.z2)*0.5)
			gl.Billboard()
			gl.Color(COLOR.text)
			gl.Text(string.format("%s risk %d", r.label, floor(r.risk)), 0, 0, 12, "cv")
			gl.PopMatrix()
		end
	end
	for w = 1, Opt('wing_labels') and WING_COUNT or 0 do
		local list = {}
		for unitID in pairs(wings[w].units) do
			local mag = magpies[unitID]
			if mag and (mag.state == "attacking" or mag.state == "returning") then
				list[#list + 1] = unitID
			end
		end
		if #list > 0 then
			local cx, cz = Centroid(list)
			if cx then
				local cy = (spGetGroundHeight(cx, cz) or 0) + 220
				gl.PushMatrix()
				gl.Translate(cx, cy, cz)
				gl.Billboard()
				gl.Color(COLOR.ready)
				gl.Text(WING_LETTER[w] .. " " .. #list, 0, 0, 18, "cv")
				gl.PopMatrix()
			end
		end
	end
	for i = 1, #marks do
		local x, y, z = spGetUnitPosition(marks[i])
		if x then
			gl.PushMatrix()
			gl.Translate(x, y + 80, z)
			gl.Billboard()
			gl.Color(COLOR.attacking)
			gl.Text(tostring(i), 0, 0, 20, "cv")
			gl.PopMatrix()
		end
	end
	if Opt('threat_map') and Opt('stockpile_watch') then
		for _, t in pairs(threats) do
			local text = ThreatLabel(t)
			if text then
				gl.PushMatrix()
				gl.Translate(t.x, t.y + 120, t.z)
				gl.Billboard()
				gl.Color(t.building and COLOR.muted or COLOR.returning)
				gl.Text(text, 0, 0, 14, "cv")
				gl.PopMatrix()
			end
		end
	end
	if Opt('reload_tracking') then
		for unitID, fired in pairs(reloadSeen) do
			local t = threats[unitID]
			local def = t and aaDefs[t.defID]
			if def and def.reload then
				local left = def.reload - (frame - fired)/30
				if left > 0 then
					gl.PushMatrix()
					gl.Translate(t.x, t.y + 90, t.z)
					gl.Billboard()
					gl.Color(COLOR.ready)
					gl.Text(string.format("reload %.0fs", left), 0, 0, 14, "cv")
					gl.PopMatrix()
				else
					reloadSeen[unitID] = nil
				end
			end
		end
	end
	gl.Color(1, 1, 1, 1)
end

local function LedgerHit(x, y)
	if not Opt('show_ledger') then
		return false
	end
	local lx, ly, lw, lh = LedgerRect()
	return x >= lx and x <= lx + lw and y <= ly and y >= ly - lh
end

function widget:IsAbove(x, y)
	if menuOpen then
		local _, mx, top, w, h = MenuLayout()
		if x >= mx and x <= mx + w and y <= top and y >= top - h then
			return true
		end
	end
	if LedgerHit(x, y) then
		return true
	end
	if not Opt('show_hud') then
		return false
	end
	local _, _, cx, cy = ChamberCentre(1)
	return Dist2D(x, y, cx, cy) <= hud.radius
end

local function GroundAt(x, y)
	local kind, pos = spTraceScreenRay(x, y, true)
	if kind == "ground" and pos then
		return pos[1], pos[3]
	end
end

function widget:MousePress(x, y, button)
	if approachMode then
		if button == 3 then
			approachMode, approachDrag = false, nil
			Alert("Approach cancelled.")
			return true
		elseif button == 1 then
			local gx, gz = GroundAt(x, y)
			if gx then
				approachDrag = {gx, gz, gx, gz}
				return true
			end
		end
		return false
	end
	if button ~= 1 then
		return false
	end
	if menuOpen and MenuClick(x, y) then
		return true
	end
	if LedgerHit(x, y) then
		local lx, ly = LedgerRect()
		if y >= ly - 24 then
			SetOption('ledger_view', NextOptionValue('ledger_view'))
		end
		return true
	end
	if not (Opt('show_hud') and widget:IsAbove(x, y)) then
		return false
	end
	local _, _, cx, cy = ChamberCentre(1)
	if Dist2D(x, y, cx, cy) <= 16 then
		ToggleMenu()
		return true
	end
	for w = 1, WING_COUNT do
		local chx, chy = ChamberCentre(w)
		if Dist2D(x, y, chx, chy) <= hud.chamber then
			local list = SelectWing(w)
			local now = frame
			if lastClick.wing == w and now - lastClick.time < 12 then
				local wx, wz = Centroid(list)
				if wx then
					Spring.SetCameraTarget(wx, spGetGroundHeight(wx, wz) or 0, wz)
				end
			end
			lastClick.wing, lastClick.time = w, now
			return true
		end
	end
	return true
end

function widget:MouseMove(x, y)
	if approachDrag then
		local gx, gz = GroundAt(x, y)
		if gx then
			approachDrag[3], approachDrag[4] = gx, gz
		end
	end
end

function widget:MouseRelease(x, y, button)
	if not approachDrag then
		return false
	end
	widget:MouseMove(x, y)
	local x1, z1, x2, z2 = approachDrag[1], approachDrag[2], approachDrag[3], approachDrag[4]
	local length = Dist2D(x1, z1, x2, z2)
	if length > 80 then
		approachPoint = {dx = (x2 - x1)/length, dz = (z2 - z1)/length}
		Alert("Next Fire attacks along the dragged direction.")
	else
		approachPoint = {x = x1, z = z1}
		Alert("Next Fire comes from the clicked point.")
	end
	approachMode, approachDrag = false, nil
	return true
end

function widget:GetTooltip(x, y)
	for w = 1, WING_COUNT do
		local chx, chy = ChamberCentre(w)
		if Dist2D(x, y, chx, chy) <= hud.chamber then
			local s = WingSummary(w)
			return string.format("Wing %s: %d Magpies, %d ready, ammo %d%%, health %d%%. Click to select, double-click to view.",
				WING_LETTER[w], s.n, s.ready, floor(s.ammo*100), floor(s.health*100))
		end
	end
	if menuOpen then
		return "Click a feature to switch it on or off."
	end
	return "Revolver. Click the middle for the feature menu."
end

widget.RevolverMenuLayout = MenuLayout
widget.RevolverLedgerRect = LedgerRect

end -- Drawing

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- Test access (read only for other widgets; used by the offline test harness)

widget.RevolverInternals = {
	magpies = function() return magpies end,
	wings = function() return wings end,
	groups = function() return groups end,
	runs = function() return runs end,
	threats = function() return threats end,
	pads = function() return pads end,
	marks = function() return marks end,
	totals = function() return totals end,
	history = function() return history end,
	reloadSeen = function() return reloadSeen end,
	alerts = function() return alerts end,
	calibration = function() return calibration end,
	approach = function() return approachPoint end,
	magpieStats = magpieStats,
	aaDefs = aaDefs,
	padDefs = padDefs,
	ReadAmmo = ReadAmmo, WingSummary = WingSummary, PickWing = PickWing,
	TableNeed = TableNeed, Need = Need, AdviseMode = AdviseMode, Allocate = Allocate, ReadyPool = ReadyPool,
	RouteRisk = RouteRisk, DistToSegment = DistToSegment, ChoosePad = ChoosePad, ReadyETA = ReadyETA, WingETA = WingETA,
	PadPlan = PadPlan, PadHealRate = PadHealRate, RunHitFactor = RunHitFactor, ExpectedHitFactor = ExpectedHitFactor,
	CalibrationTable = CalibrationTable, CardLines = CardLines, Export = Export, LoadHistory = LoadHistory, CSVLine = CSVLine,
	Fire = function(...) return Fire(...) end, Mark = function() return Mark() end, ClearMarks = function() return ClearMarks() end,
	Recall = function() return Recall() end, SelectWing = function(w) return SelectWing(w) end,
	SelectReady = function() return SelectReady() end, SetApproach = function() return SetApproach() end,
	PoolPartial = function() return PoolPartial() end, ToggleCalibration = function() return ToggleCalibration() end,
	ToggleMenu = function() return ToggleMenu() end, AssignSelected = function(w) return AssignSelected(w) end,
	menuOpen = function() return menuOpen end, approachMode = function() return approachMode end,
	routes = function() return routeCache end, losMemory = function() return losMemory end,
	StaleCells = StaleCells, CellAge = CellAge, SweepLos = SweepLos, FleetAdvice = FleetAdvice, TargetTable = TargetTable,
	StockEstimate = StockEstimate, ThreatLabel = ThreatLabel, MissilesCovering = MissilesCovering, FinishFrame = FinishFrame,
	WholeWings = WholeWings, SetOption = SetOption, NextOptionValue = NextOptionValue, UpdateRoutes = UpdateRoutes,
}
