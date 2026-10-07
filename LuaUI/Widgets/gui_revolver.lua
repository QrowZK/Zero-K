--------------------------------------------------------------------------------
--------------------------------------------------------------------------------

function widget:GetInfo()
	return {
		name      = "Revolver",
		desc      = "Fleet manager for Magpies. Groups them into six wings, shows how many each target needs, keeps shots for ordered targets, balances pads, maps enemy anti-air, records every sortie, tells allies about attacks and lists their !air requests.",
		author    = "QrowZK",
		date      = "October 2026",
		version   = "2026-10-07a",
		license   = "GNU GPL, v2 or later",
		layer     = 10,
		enabled   = false,
		handler   = true,
	}
end

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- Speedups


local floor, ceil, sqrt, min, max = math.floor, math.ceil, math.sqrt, math.min, math.max
local pi, cos, sin = math.pi, math.cos, math.sin

local customCmds = VFS.Include("LuaRules/Configs/customcmds.lua")
-- Commands and fire states, plus a few helpers (a table: the main chunk is near Lua's 200-local limit)
local C = {
	ATTACK = CMD.ATTACK, MOVE = CMD.MOVE, FIRE_STATE = CMD.FIRE_STATE, OPT_SHIFT = CMD.OPT_SHIFT,
	OPT_INTERNAL = CMD.OPT_INTERNAL or 8,
	REARM = customCmds.REARM, FIND_PAD = customCmds.FIND_PAD, RETREAT = customCmds.RETREAT,
	LOOP_ATTACK = customCmds.LOOP_ATTACK, SET_TARGET = customCmds.UNIT_SET_TARGET,
	HOLD = 0, FREE = 2,
}
C.killHome = {} -- Magpies whose hand-ordered target just died, sent home after this poll

-- "1 Magpie", "3 Magpies"
function C.Magpies(n)
	return n .. (n == 1 and " Magpie" or " Magpies")
end

local defs = VFS.Include("LuaUI/Configs/revolver_defs.lua")

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- Unit data

local magpieDefID = UnitDefNames.planesupport and UnitDefNames.planesupport.id

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

-- Positions are fractions of the screen so they survive resolution changes. Both panels can be dragged.
-- Sizes are at 1080p and 100%; both panels scale with screen height and their size option (drag the grip on a panel).
local HUD_DEFAULT = {fx = 1 - 210/1920, fy = 270/1080}
local LEDGER_DEFAULT = {fx = 20/1920, fy = 1 - 240/1080}
local hud = {fx = HUD_DEFAULT.fx, fy = HUD_DEFAULT.fy, radius = 92, chamber = 30, scale = 1}
local ledgerPanel = {fx = LEDGER_DEFAULT.fx, fy = LEDGER_DEFAULT.fy, w = 380, h = 226, scale = 1}
local menuPanel = {fx = 0.5, fy = 0.5} -- centre of the feature menu; dragged by its title bar
local dragging -- panel being dragged or clicked: {what, x0, y0, fx0, fy0, moved, onClick}

-- Allies: attack notices in ally chat and the !air request panel (one table: the main chunk is near Lua's 200-local limit)
local Allies = {
	DEFAULT = {fx = 1295/1920, fy = 400/1080}, -- request panel's top left corner, left of the cylinder
	requests = {}, -- newest first: {pid, name, team, note, x, z, where, source, frame, answered}
	pending = {},  -- target unitID -> {n, name, x, z, frame, req}: attacks not posted yet
	reported = {}, -- target unitID -> frame it was last posted
	hurt = {},     -- allied teamID -> {x, z, frame}: where its units were last hit
	lastSent = -10000,
}
Allies.panel = {fx = Allies.DEFAULT.fx, fy = Allies.DEFAULT.fy}

local AimOf, Watch
local Fire, Mark, ClearMarks, Recall, SelectWing, SelectReady, SetApproach, PoolPartial, ToggleCalibration
local ToggleMenu, AssignSelected, ResetSizes

local ROOT = 'Settings/Unit Behaviour/Revolver'
local PATH = {
	cylinder = ROOT .. '/Cylinder',
	reload   = ROOT .. '/Reload',
	sights   = ROOT .. '/Sights',
	trigger  = ROOT .. '/Trigger',
	radar    = ROOT .. '/Radar',
	ledger   = ROOT .. '/Ledger',
	allies   = ROOT .. '/Allies',
	grip     = ROOT .. '/Grip',
}

local function Switch(name, desc, value, path)
	return {name = name, desc = desc, type = 'bool', value = value, path = path, noHotkey = true}
end

options_path = ROOT
options_order = {
	-- Cylinder
	'auto_wing', 'wing_size', 'assign_mode', 'ready_ammo', 'ready_health', 'spare_wing', 'show_hud', 'hud_size', 'wing_labels', 'fleet_advisor',
	-- Reload
	'pad_balance', 'retreat_state',
	-- Sights
	'show_card', 'live_correction', 'allocate', 'horizon', 'auto_style', 'slow_chain', 'kill_confirm',
	-- Trigger
	'hold_fire', 'release_near_target', 'time_on_target', 'hand_together', 'staging_distance', 'rotate_fire',
	-- Radar
	'threat_map', 'threat_style', 'path_card', 'route_lines', 'stale_intel', 'stale_seconds', 'route_alert', 'fighter_alert', 'fighter_pullback', 'stockpile_watch', 'stockpile_speed', 'stockpile_cap', 'reload_tracking',
	-- Ledger
	'ledger_tracking', 'show_ledger', 'ledger_size', 'ledger_view', 'career_history', 'export_csv',
	-- Allies
	'ally_notify', 'air_requests', 'request_minutes', 'requests_size',
	-- Grip
	'sounds', 'reset_positions', 'open_menu', 'fire', 'mark', 'clear_marks', 'recall', 'select_ready',
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
	hud_size = {name = 'Cylinder size (%)', desc = 'Also: drag the grip at the lower right of the cylinder.', type = 'number', value = 140, min = 60, max = 300, step = 10, path = PATH.cylinder},
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
	time_on_target = Switch('Arrive together', 'Fire: Magpies further from the target set off first and the closer ones wait their turn, so the whole attack arrives at once.', true, PATH.trigger),
	hand_together = Switch('Arrive together on right-click', 'The same for attacks you order by right-clicking an enemy with Magpies selected.', false, PATH.trigger),
	staging_distance = {name = 'Approach distance', desc = 'How far out from the target a run set with Set approach begins.', type = 'number', value = 1300, min = 700, max = 2500, step = 50, path = PATH.trigger},
	rotate_fire = Switch('Rotate fire', 'When a wing runs dry, the next chambered wing launches at the same targets.', false, PATH.trigger),

	-- Radar
	threat_map = Switch('Anti-air threat map', nil, true, PATH.radar),
	threat_style = {
		name = 'Threat map style', desc = 'Shaded: see-through discs, darker where coverage overlaps.', type = 'radioButton', value = 'fill', path = PATH.radar,
		items = {
			{key = 'fill', name = 'Shaded'},
			{key = 'outline', name = 'Outlines'},
		},
	},
	path_card = {
		name = 'Flight path card', desc = 'With Magpies selected, shows what a straight flight to the cursor would cross. While ordering: during a move, attack, fight or patrol order.', type = 'radioButton', value = 'command', path = PATH.radar,
		items = {
			{key = 'command', name = 'While ordering'},
			{key = 'always', name = 'Always'},
			{key = 'off', name = 'Off'},
		},
	},
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
	ledger_size = {name = 'Ledger size (%)', desc = 'Also: drag the grip in the lower right corner of the ledger.', type = 'number', value = 120, min = 60, max = 300, step = 10, path = PATH.ledger},
	ledger_view = {
		name = 'Ledger graph', type = 'radioButton', value = 'runs', path = PATH.ledger,
		items = {
			{key = 'runs', name = 'Hit factor per run'},
			{key = 'targets', name = 'Hit factor per target type'},
		},
	},
	career_history = Switch('Career history', 'Keep a summary of every game and show the trend.', true, PATH.ledger),
	export_csv = Switch('Save sorties to file', 'Writes LuaUI/Config/Revolver/*.csv at the end of the game.', true, PATH.ledger),

	-- Allies
	ally_notify = {
		name = 'Tell allies about Magpie attacks', type = 'radioButton', value = 'off', path = PATH.allies,
		desc = 'Posts in ally chat how many Magpies are attacking what, and roughly where: at most one line every 8 seconds, and each target once in 30 seconds. With map ping, the biggest attack is also marked on the map.',
		items = {
			{key = 'off', name = 'Off'},
			{key = 'chat', name = 'Ally chat'},
			{key = 'ping', name = 'Ally chat and map ping'},
		},
	},
	air_requests = Switch('List !air requests from allies', 'Allies who type !air in chat, or put !air on a map point, are listed in a panel. Click a row to look there.', true, PATH.allies),
	request_minutes = {name = 'Keep requests for (minutes)', type = 'number', value = 3, min = 1, max = 10, step = 1, path = PATH.allies},
	requests_size = {name = 'Air request panel size (%)', desc = 'Also: drag the grip in the lower right corner of the panel.', type = 'number', value = 100, min = 60, max = 300, step = 10, path = PATH.allies},

	-- Grip
	sounds = Switch('Sounds', nil, true, PATH.grip),
	reset_positions = {name = 'Reset panel positions and sizes', desc = 'The cylinder, ledger, menu and air request panel.', type = 'button', path = PATH.grip, OnChange = function()
		hud.fx, hud.fy = HUD_DEFAULT.fx, HUD_DEFAULT.fy
		ledgerPanel.fx, ledgerPanel.fy = LEDGER_DEFAULT.fx, LEDGER_DEFAULT.fy
		menuPanel.fx, menuPanel.fy = 0.5, 0.5
		Allies.panel.fx, Allies.panel.fy = Allies.DEFAULT.fx, Allies.DEFAULT.fy
		ResetSizes()
	end},
	open_menu = {name = 'Open Revolver menu', desc = 'Switch Revolver features on and off. Also opens from the middle of the cylinder.', type = 'button', path = PATH.grip, OnChange = function() ToggleMenu() end},
	fire = {name = 'Fire', desc = 'Send chambered Magpies at the marked targets, or the enemy under the cursor.', type = 'button', path = PATH.grip, OnChange = function() Fire() end},
	mark = {name = 'Mark target', desc = 'Add the enemy under the cursor to the target list.', type = 'button', path = PATH.grip, OnChange = function() Mark() end},
	clear_marks = {name = 'Clear marks', type = 'button', path = PATH.grip, OnChange = function() ClearMarks() end},
	recall = {name = 'Recall selected', desc = 'Send the selected Magpies, or every airborne wing if none are selected, to pads.', type = 'button', path = PATH.grip, OnChange = function() Recall() end},
	select_ready = {name = 'Select chambered wings', type = 'button', path = PATH.grip, OnChange = function() SelectReady() end},
	approach = {name = 'Set approach', desc = 'Then drag an arrow on the map the way the next attack should fly over its target, or click where it should come in from. Used by the next Fire, or the next right-click attack with Magpies selected.', type = 'button', path = PATH.grip, OnChange = function() SetApproach() end},
	pool = {name = 'Pool Magpies with ammo left', desc = 'Selected Magpies (or all) with ammo left below Ready at ammo join wing F; any flying home wait beside the pad instead of landing, which would throw their ammo away. They go back to their wing once rearmed.', type = 'button', path = PATH.grip, OnChange = function() PoolPartial(true) end},
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
	{title = 'Trigger', keys = {'hold_fire', 'release_near_target', 'time_on_target', 'hand_together', 'rotate_fire'}},
	{title = 'Radar', keys = {'threat_map', 'threat_style', 'path_card', 'route_lines', 'stale_intel', 'route_alert', 'fighter_alert', 'fighter_pullback', 'stockpile_watch', 'reload_tracking'}},
	{title = 'Ledger', keys = {'ledger_tracking', 'show_ledger', 'ledger_view', 'career_history', 'export_csv'}},
	{title = 'Allies', keys = {'ally_notify', 'air_requests'}},
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
local struck = {}      -- enemy unitID -> health watch that credits damage and kills to runs
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
	local ax, _, az = Spring.GetUnitPosition(a)
	local bx, _, bz = Spring.GetUnitPosition(b)
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
		local x, _, z = Spring.GetUnitPosition(list[i])
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
	if not (unitID and Spring.ValidUnitID(unitID)) or Spring.GetUnitIsDead(unitID) then
		return false
	end
	local allyTeam = Spring.GetUnitAllyTeam(unitID)
	return allyTeam ~= nil and allyTeam ~= myAllyTeamID
end

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- Allies: attack notices in ally chat, and allies' !air requests

-- Rough place on the map, by thirds: "north-west", "east", "mid".
function Allies.Where(x, z)
	local sizeX, sizeZ = Game.mapSizeX or 1, Game.mapSizeZ or 1
	local ns = (z < sizeZ/3 and "north") or (z > sizeZ*2/3 and "south") or nil
	local ew = (x < sizeX/3 and "west") or (x > sizeX*2/3 and "east") or nil
	if ns and ew then
		return ns .. "-" .. ew
	end
	return ns or ew or "mid"
end

function Allies.UnitName(unitID)
	local defID = Spring.GetUnitDefID(unitID)
	local ud = defID and UnitDefs[defID]
	return ud and (ud.humanName or ud.name) or "a radar contact"
end

-- An attack answers the nearest request within 1600 elmos.
function Allies.Answer(x, z)
	local best, bestD
	for i = 1, #Allies.requests do
		local req = Allies.requests[i]
		local d = Dist2D(x, z, req.x, req.z)
		if d <= 1600 and (not bestD or d < bestD) then
			best, bestD = req, d
		end
	end
	if best and not best.answered then
		best.answered = frame
	end
	return best
end

-- Magpies just sent at an enemy, by Fire, a retarget or a hand order: answer a request near it and
-- queue a notice for ally chat.
function Allies.Dispatch(target, n)
	if not (n and n > 0) or not IsAliveEnemy(target) then
		return
	end
	local x, _, z = Spring.GetUnitPosition(target)
	if not x then
		return
	end
	local req = Allies.Answer(x, z)
	if Opt('ally_notify') == 'off' then
		return
	end
	local p = Allies.pending[target]
	if not p then
		p = {n = 0, name = Allies.UnitName(target), x = x, z = z, frame = frame}
		Allies.pending[target] = p
	end
	p.n = p.n + n
	if req and req.pid ~= Spring.GetMyPlayerID() then
		p.req = req.name
	end
end

-- Post queued notices as one line, a moment after the first so a whole Fire goes together. At most one
-- line every 8 s; a target posted in the last 30 s is left out.
function Allies.Flush()
	local first
	for _, p in pairs(Allies.pending) do
		first = min(first or p.frame, p.frame)
	end
	if not first or frame - first < 20 or frame - Allies.lastSent < 240 then
		return
	end
	local list = {}
	for target, p in pairs(Allies.pending) do
		local seen = Allies.reported[target]
		if not (seen and frame - seen < 900) then
			p.target = target
			list[#list + 1] = p
		end
	end
	Allies.pending = {}
	if #list == 0 or Opt('ally_notify') == 'off' then
		return
	end
	table.sort(list, function(a, b)
		if a.n ~= b.n then
			return a.n > b.n
		end
		return a.target < b.target
	end)
	local parts = {}
	for i = 1, #list do
		local p = list[i]
		Allies.reported[p.target] = frame
		if i <= 3 then
			parts[i] = p.n .. " on " .. p.name .. " (" .. Allies.Where(p.x, p.z) .. ")" .. (p.req and (" for " .. p.req) or "")
		end
	end
	local more = #list - 3
	local text = "Magpies: " .. table.concat(parts, ", ")
	if more > 0 then
		text = text .. " and " .. more .. (more == 1 and " more target" or " more targets")
	end
	Spring.SendCommands("say a:" .. text .. ".")
	Allies.lastSent = frame
	if Opt('ally_notify') == 'ping' then
		local p = list[1]
		Spring.MarkerAddPoint(p.x, Spring.GetGroundHeight(p.x, p.z) or 0, p.z, "Magpies: " .. p.n, false)
	end
end

-- "!air" as a word, in any case.
function Allies.HasAir(text)
	return (" " .. text:lower() .. " "):find("[%s%p]!air[%s%p]") ~= nil
end

-- The player who sent a chat line, if they play on our side (ourselves too, so it can be tried alone).
function Allies.Player(name)
	local players = Spring.GetPlayerList() or {}
	for i = 1, #players do
		local playerName, _, spec, teamID, allyTeamID = Spring.GetPlayerInfo(players[i], false)
		if playerName == name then
			if spec or allyTeamID ~= myAllyTeamID then
				return nil
			end
			return players[i], teamID
		end
	end
	return nil
end

-- Where an ally's ground units were last hit, noted at most twice a second per team.
function Allies.Hurt(unitID, teamID)
	local h = Allies.hurt[teamID]
	if h and frame - h.frame < 15 then
		return
	end
	local x, _, z = Spring.GetUnitPosition(unitID)
	if x then
		Allies.hurt[teamID] = {x = x, z = z, frame = frame}
	end
end

-- Best guess at where a chat request wants Magpies: where the player's units were hit in the last
-- 20 s, else their commander, else the middle of their units.
function Allies.Locate(teamID)
	local h = Allies.hurt[teamID]
	if h and frame - h.frame <= 600 then
		return h.x, h.z, "under fire"
	end
	local units = Spring.GetTeamUnits(teamID) or {}
	for i = 1, #units do
		local defID = Spring.GetUnitDefID(units[i])
		local cp = defID and UnitDefs[defID].customParams
		if cp and (cp.commtype or cp.dynamic_comm) then
			local x, _, z = Spring.GetUnitPosition(units[i])
			if x then
				return x, z, "commander"
			end
		end
	end
	local x, z = Centroid(units)
	if x then
		return x, z, "their units"
	end
	return nil
end

function Allies.Remove(playerID)
	for i = #Allies.requests, 1, -1 do
		if Allies.requests[i].pid == playerID then
			table.remove(Allies.requests, i)
		end
	end
end

-- A new request replaces the player's earlier one. Map points give the place; chat requests are located.
function Allies.Request(playerID, name, teamID, text, x, z)
	local note = text:gsub("![Aa][Ii][Rr]", " "):gsub("%s+", " "):gsub("^[%s%p]+", ""):gsub("%s+$", "")
	if #note > 28 then
		note = note:sub(1, 25):gsub("[\192-\255][\128-\191]*$", "") .. "..."
	end
	local source = "map point"
	if not x then
		x, z, source = Allies.Locate(teamID)
	end
	if not x then
		x, z, source = (Game.mapSizeX or 0)/2, (Game.mapSizeZ or 0)/2, "unknown"
	end
	Allies.Remove(playerID)
	local req = {pid = playerID, name = name, team = teamID, note = note, x = x, z = z,
		where = Allies.Where(x, z), source = source, frame = frame}
	table.insert(Allies.requests, 1, req)
	Allies.requests[13] = nil
	local say = name .. " asks for air support (" .. req.where .. ")" .. (note ~= "" and (": " .. note) or "")
	Alert(say .. (say:find("[%.!?]$") and "" or "."), "air" .. playerID, "sounds/beep4.wav")
	return req
end

-- Chat lines read "<Name> Allies: text" (ally chat) or "<Name> text" (all chat). Chat to spectators,
-- whispers and spectators' lines ("[Name] text") are left out.
function Allies.Heard(line)
	if not Opt('air_requests') or not line:lower():find("!air", 1, true) then
		return
	end
	local name, text = line:match("^<([^>]+)> (.*)$")
	if not name then
		return
	end
	local channel = text:match("^(%a+): ")
	if channel == "Spectators" or channel == "Private" then
		return
	elseif channel == "Allies" then
		text = text:sub(9)
	end
	if Allies.HasAir(text) then
		local playerID, teamID = Allies.Player(name)
		if playerID then
			Allies.Request(playerID, name, teamID, text)
		end
	end
end

-- Requests expire after the set time, or 30 s after Magpies answered them.
function Allies.Update()
	if not Opt('air_requests') then
		Allies.requests = {}
	end
	local keep = Opt('request_minutes')*1800
	for i = #Allies.requests, 1, -1 do
		local req = Allies.requests[i]
		if frame - req.frame > keep or (req.answered and frame - req.answered > 900) then
			table.remove(Allies.requests, i)
		end
	end
	for target, f in pairs(Allies.reported) do
		if frame - f > 900 then
			Allies.reported[target] = nil
		end
	end
end

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- Magpie state

-- ammoFraction is nil both when full and when empty; noammo says which.
local function ReadAmmo(unitID)
	local noAmmo = Spring.GetUnitRulesParam(unitID, "noammo") or 0
	if noAmmo == 1 or noAmmo == 2 then
		return 0, noAmmo
	end
	return Spring.GetUnitRulesParam(unitID, "ammoFraction") or 1, noAmmo
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
	if mag.homeFrame then
		return "returning"
	end
	local cmdID = Spring.GetUnitCurrentCommand(mag.unitID)
	if cmdID == C.REARM or cmdID == C.FIND_PAD then
		return "returning"
	elseif cmdID == C.ATTACK or cmdID == C.SET_TARGET or cmdID == CMD.FIGHT or cmdID == CMD.AREA_ATTACK then
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
	mag.wing, mag.poolFrom = w, nil
	local retreat = Opt('retreat_state')
	if retreat ~= 'keep' and C.RETREAT then
		Spring.GiveOrderToUnit(unitID, C.RETREAT, {tonumber(retreat)}, 0)
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
	local health, maxHealth = Spring.GetUnitHealth(unitID)
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
	local defID = Spring.GetUnitDefID(targetID)
	local ud = defID and UnitDefs[defID]
	if not ud then
		return 1, 0, horizon, "unknown"
	end
	local health, maxHealth = Spring.GetUnitHealth(targetID)
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
	local x, y, z = Spring.GetUnitPosition(unitID)
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
	local _, _, _, _, progress = Spring.GetUnitHealth(unitID)
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
	if Spring.IsPosInLos(x, Spring.GetGroundHeight(x, z) or 0, z, myAllyTeamID) then
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

-- What a straight flight crosses: time, expected damage per Magpie, the anti-air on the way and where it
-- starts and stops (fractions of the line), stockpiled missiles in reach, fighters, and unscouted stretches.
local function PathInsight(x1, z1, x2, z2)
	local length = Dist2D(x1, z1, x2, z2)
	local info = {
		x1 = x1, z1 = z1, x2 = x2, z2 = z2, length = length, time = length/magpieStats.speed,
		risk = RouteRisk(x1, z1, x2, z2), spans = {}, aa = {}, aaNames = {}, missiles = 0, exact = true,
		stockpilers = 0, fighters = 0, unseen = 0,
	}
	local dx, dz = x2 - x1, z2 - z1
	local a = dx*dx + dz*dz
	for _, t in pairs(threats) do
		local fx, fz = x1 - t.x, z1 - t.z
		local c = fx*fx + fz*fz - t.range*t.range
		local t1, t2
		if a > 0 then
			local b = 2*(fx*dx + fz*dz)
			local disc = b*b - 4*a*c
			if disc >= 0 then
				local root = sqrt(disc)
				t1, t2 = max(0, (-b - root)/(2*a)), min(1, (-b + root)/(2*a))
			end
		elseif c <= 0 then
			t1, t2 = 0, 1
		end
		if t1 and t2 >= t1 then
			if t.fighter then
				info.fighters = info.fighters + 1
			elseif not t.building then
				local def = aaDefs[t.defID]
				local danger = max(0, min(1, 1 - t.ttk/15))
				local stock, _, exact = StockEstimate(t)
				if stock then
					info.missiles = info.missiles + stock
					info.stockpilers = info.stockpilers + 1
					info.exact = info.exact and exact
					danger = (stock > 0) and 1 or 0.2
				end
				info.spans[#info.spans + 1] = {t1, t2, danger}
				if not info.aa[def.name] then
					info.aaNames[#info.aaNames + 1] = def.name
				end
				info.aa[def.name] = (info.aa[def.name] or 0) + 1
			end
		end
	end
	table.sort(info.aaNames, function(p, q)
		if info.aa[p] ~= info.aa[q] then
			return info.aa[p] > info.aa[q]
		end
		return p < q
	end)
	-- Share of the line nobody has seen within the stale time.
	local steps = max(1, ceil(length/(LOS_CELL*0.5)))
	local unseen = 0
	for i = 0, steps do
		local f = i/steps
		if CellAge(x1 + dx*f, z1 + dz*f) > Opt('stale_seconds') then
			unseen = unseen + 1
		end
	end
	info.unseen = unseen/(steps + 1)
	return info
end

-- The lines of the flight path card.
local function PathLines(info, selected)
	local lines = {}
	local ammo, n = 0, 0
	for i = 1, #selected do
		local mag = magpies[selected[i]]
		if mag then
			ammo, n = ammo + mag.ammo, n + 1
		end
	end
	lines[1] = {string.format("%d Magpie%s, ammo %d%%, flight %.0f s", n, n == 1 and "" or "s", n > 0 and floor(ammo/n*100 + 0.5) or 0, info.time), "text"}
	local share = info.risk/magpieStats.maxHealth
	if info.risk < 1 then
		lines[#lines + 1] = {"No known anti-air on this line.", "ready"}
	elseif share >= 1 then
		lines[#lines + 1] = {string.format("Lethal: about %d damage per Magpie (%d HP each)", floor(info.risk), magpieStats.maxHealth), "returning"}
	else
		lines[#lines + 1] = {string.format("About %d damage per Magpie (%d%% of its health)", floor(info.risk), floor(share*100 + 0.5)), share > 0.5 and "returning" or "attacking"}
	end
	if #info.aaNames > 0 then
		local parts = {}
		for i = 1, min(4, #info.aaNames) do
			local name = info.aaNames[i]
			parts[#parts + 1] = info.aa[name] .. " " .. name
		end
		if #info.aaNames > 4 then
			parts[#parts + 1] = "more"
		end
		lines[#lines + 1] = {"Crosses " .. table.concat(parts, ", "), "muted"}
	end
	if info.stockpilers > 0 then
		lines[#lines + 1] = {string.format("%d stockpiler%s in reach: %s%d missile%s", info.stockpilers, info.stockpilers == 1 and "" or "s",
			info.exact and "" or "at least ", info.missiles, info.missiles == 1 and "" or "s"), info.missiles > 0 and "returning" or "muted"}
	end
	if info.fighters > 0 then
		lines[#lines + 1] = {string.format("%d enemy fighter%s near the line", info.fighters, info.fighters == 1 and "" or "s"), "returning"}
	end
	if info.unseen > 0.05 then
		lines[#lines + 1] = {string.format("%d%% of the line unseen for %d s or more", floor(info.unseen*100 + 0.5), Opt('stale_seconds')), "muted"}
	end
	-- Home again afterwards
	local best
	for padID in pairs(pads) do
		local px, _, pz = Spring.GetUnitPosition(padID)
		if px then
			local d = Dist2D(info.x2, info.z2, px, pz)
			best = (not best or d < best) and d or best
		end
	end
	if best then
		lines[#lines + 1] = {string.format("Back to the nearest pad: %.0f s", best/magpieStats.speed), "muted"}
	end
	return lines
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
	return Spring.GetUnitRulesParam(padID, "padExcluded" .. myTeamID) ~= 1
end

-- Pick the pad with the shortest flight plus wait.
local function ChoosePad(unitID)
	local x, _, z = Spring.GetUnitPosition(unitID)
	if not x then
		return nil
	end
	local mag = magpies[unitID]
	local best, bestScore
	for padID, pad in pairs(pads) do
		if PadUsable(padID) then
			local px, _, pz = Spring.GetUnitPosition(padID)
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

-- When each grounded or homebound Magpie is ready again. Each pad serves its Magpies first come, first
-- served, one per slot: flight to the pad, wait for a free slot, rearm, then repair to full health.
local padQueue = {frame = -1000, eta = {}, parts = {}}

local function PadQueue()
	if frame - padQueue.frame < 15 and padQueue.frame >= 0 then
		return padQueue
	end
	local byPad = {}
	local eta, parts = {}, {}
	for unitID, mag in pairs(magpies) do
		if mag.noAmmo ~= 0 or mag.state == "returning" then
			local padID = mag.pad
			if not (padID and pads[padID]) then
				padID = ChoosePad(unitID) -- where it will most likely go
			end
			if padID then
				local pad = pads[padID]
				local onPad = (mag.noAmmo == 2 or mag.noAmmo == 3)
				local flight = onPad and 0 or (UnitDist2D(unitID, padID) or 0)/magpieStats.speed
				local rearm = magpieStats.rearmSeconds
				if mag.noAmmo == 2 then
					rearm = max(0, rearm - (frame - (mag.rearmStart or frame))/30)
				elseif mag.noAmmo == 3 then
					rearm = 0
				end
				local repair = RepairSeconds(mag, pad)
				byPad[padID] = byPad[padID] or {}
				local list = byPad[padID]
				list[#list + 1] = {unitID = unitID, onPad = onPad, flight = flight, rearm = rearm, repair = repair}
			end
		end
	end
	for padID, list in pairs(byPad) do
		table.sort(list, function(a, b)
			if a.onPad ~= b.onPad then
				return a.onPad
			end
			if a.flight ~= b.flight then
				return a.flight < b.flight
			end
			return a.unitID < b.unitID
		end)
		local free = {}
		for i = 1, max(1, pads[padID].cap) do
			free[i] = 0
		end
		for i = 1, #list do
			local e = list[i]
			local slot = 1
			for j = 2, #free do
				if free[j] < free[slot] then
					slot = j
				end
			end
			local start = max(e.flight, free[slot])
			local finish = start + e.rearm + e.repair
			free[slot] = finish
			eta[e.unitID] = frame + finish*30 -- frame it is ready, so the estimate keeps counting down between updates
			parts[e.unitID] = {flight = e.flight, wait = start - e.flight, rearm = e.rearm, repair = e.repair, pad = padID}
		end
	end
	padQueue.frame, padQueue.eta, padQueue.parts = frame, eta, parts
	return padQueue
end

local function ReadyETA(mag)
	if mag.noAmmo == 0 and mag.state ~= "returning" then
		return 0
	end
	local readyFrame = PadQueue().eta[mag.unitID]
	if readyFrame then
		return max(0, (readyFrame - frame)/30)
	end
	-- No pad at all: rearm and repair at the default rate once it gets one.
	return magpieStats.rearmSeconds + RepairSeconds(mag)
end

-- Seconds until the whole wing is ready, and the breakdown for the Magpie that takes longest.
local function WingETA(w)
	local worst, worstParts = 0, nil
	for unitID in pairs(wings[w].units) do
		local mag = magpies[unitID]
		if mag then
			local eta = ReadyETA(mag)
			if eta > worst then
				worst, worstParts = eta, padQueue.parts[unitID]
			end
		end
	end
	return worst, worstParts
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
		local defID = Spring.GetUnitDefID(targets[i])
		run.targets[#run.targets + 1] = defID and UnitDefs[defID].name or "unknown"
	end
	runs[#runs + 1] = run
	return run
end

-- Share of the damage aimed bursts could have done that landed. Bursts fired out of range are counted as wasted instead.
local function RunHitFactor(run)
	local aimed = run.bursts - run.wasted
	if aimed <= 0 then
		return nil
	end
	return run.damage/(aimed*magpieStats.damagePerBurst)
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
	if not C.LOOP_ATTACK then
		return "?"
	end
	local index = Spring.FindUnitCmdDesc(unitID, C.LOOP_ATTACK)
	local descs = index and Spring.GetUnitCmdDescs(unitID, index, index)
	local desc = descs and descs[1]
	if desc and desc.params then
		return (tonumber(desc.params[1]) == 1) and "loopback" or "strafe"
	end
	return "?"
end

local function CurrentTarget(unitID)
	local cmdID, _, _, p1, p2 = Spring.GetUnitCurrentCommand(unitID)
	if cmdID == C.ATTACK and p1 and not p2 then
		return p1
	end
	return nil
end

-- Widgets only get UnitDamaged and UnitDestroyed for their own allyteam's units, so damage dealt is read off
-- the health of what Magpies are shooting at. Each burst opens credit for its damage on the target for a
-- moment; health the target loses in that time is paid out of the credit.

-- What a Magpie is shooting at: its weapon's target, else its group's or its order's.
function AimOf(mag)
	local kind, _, targetID = Spring.GetUnitWeaponTarget(mag.unitID, 1)
	if kind == 1 and targetID then
		return targetID
	end
	return (mag.group and groups[mag.group] and groups[mag.group].target) or CurrentTarget(mag.unitID)
end

function Watch(unitID)
	if not unitID then
		return nil
	end
	local s = struck[unitID]
	if not s then
		if not IsAliveEnemy(unitID) then
			return nil
		end
		local health = Spring.GetUnitHealth(unitID)
		if not health then
			return nil
		end
		local x, y, z = Spring.GetUnitPosition(unitID)
		s = {health = health, credit = 0, expire = 0, defID = Spring.GetUnitDefID(unitID), x = x, y = y, z = z}
		struck[unitID] = s
	end
	s.watched = frame
	return s
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
			local target = AimOf(mag)
			run = NewRun(w, target and {target} or {}, MagpieMode(mag.unitID), false)
			runByWing[w] = run
		end
		run.magpies = run.magpies + 1
		mag.run = run
	end
	run.bursts = run.bursts + 1
	run.last = frame
	local target = AimOf(mag)
	if target then
		local d = UnitDist2D(mag.unitID, target)
		if d and d > magpieStats.range + 100 then
			run.wasted = run.wasted + 1
		else
			-- Damage this burst can account for, used up as the target's health drops.
			local s = Watch(target)
			if s then
				s.credit = s.credit + magpieStats.damagePerBurst
				s.expire = frame + 45
				s.run = run
			end
		end
	else
		run.wasted = run.wasted + 1
	end
end

-- Health drops on watched targets, paid out of burst credit. A target that dies with recent Magpie damage is a kill.
local function KillCredit(unitID, s)
	struck[unitID] = nil
	if s.hitRun and s.lastHit and frame - s.lastHit < 30*5 then
		local cost = UnitDefs[s.defID] and UnitDefs[s.defID].metalCost or 0
		s.hitRun.kills = s.hitRun.kills + 1
		s.hitRun.killValue = s.hitRun.killValue + cost
		totals.metalKilled = totals.metalKilled + cost
		return true
	end
	return false
end

local function UpdateStruck()
	for unitID, s in pairs(struck) do
		local health = Spring.GetUnitHealth(unitID)
		if health then
			local drop = s.health - health
			if drop > 0 and s.credit > 0 and s.run then
				local got = min(drop, s.credit)
				s.credit = s.credit - got
				s.run.damage = s.run.damage + got
				s.hitRun, s.lastHit = s.run, frame
			end
			s.health = health
			s.x, s.y, s.z = Spring.GetUnitPosition(unitID)
			if frame > s.expire then
				s.credit = 0
			end
			if Spring.GetUnitIsDead(unitID) then
				KillCredit(unitID, s)
			elseif s.credit == 0 and frame - s.watched > 30*5 then
				struck[unitID] = nil
			end
		else
			-- Gone. If its last spot is in sight it did not just walk out of view: it died.
			if s.x and Spring.IsPosInLos(s.x, s.y or 0, s.z, myAllyTeamID) then
				KillCredit(unitID, s)
			end
			struck[unitID] = nil
		end
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

local FILES = {}
FILES.CSV_HEADER = "run,wing,start_s,end_s,targets,mode,launched,magpies,bursts,wasted_bursts,landing_waste,damage,hit_factor,sim_hit_factor,kills,kill_metal,magpies_lost"
FILES.HISTORY_HEADER = "date,runs,bursts,damage,hit_factor,kills,kill_metal,magpies_lost,metal_lost"
FILES.EXPORT_DIR = "LuaUI/Config/Revolver/"

local function GameTotals()
	local bursts, aimed, damage, kills, lost = 0, 0, 0, 0, 0
	for i = 1, #runs do
		local run = runs[i]
		bursts, damage, kills, lost = bursts + run.bursts, damage + run.damage, kills + run.kills, lost + run.lost
		aimed = aimed + run.bursts - run.wasted
	end
	local hit = (aimed > 0) and damage/(aimed*magpieStats.damagePerBurst) or nil
	return {runs = #runs, bursts = bursts, aimed = aimed, damage = damage, kills = kills, lost = lost, hit = hit}
end

local function LoadHistory()
	history = {}
	if not Opt('career_history') then
		return
	end
	local file = io.open(FILES.EXPORT_DIR .. "history.csv", "r")
	if not file then
		return
	end
	for line in file:lines() do
		local cells = {}
		for cell in (line .. ","):gmatch("([^,]*),") do
			cells[#cells + 1] = cell
		end
		local hit = tonumber(cells[5])
		-- Games recorded before damage was measured from health show bursts with no damage: skip them.
		local brokenRow = (tonumber(cells[3]) or 0) > 0 and tonumber(cells[4]) == 0
		if hit and not brokenRow then
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
	Spring.CreateDir(FILES.EXPORT_DIR)
	local stamp = os.date("%Y%m%d_%H%M%S")
	local file = io.open(FILES.EXPORT_DIR .. "sorties_" .. stamp .. ".csv", "w")
	if not file then
		return false
	end
	file:write(FILES.CSV_HEADER .. "\n")
	for i = 1, #runs do
		file:write(CSVLine(runs[i]) .. "\n")
	end
	file:close()

	local t = GameTotals()
	local newHistory = not io.open(FILES.EXPORT_DIR .. "history.csv", "r")
	local hist = Opt('career_history') and io.open(FILES.EXPORT_DIR .. "history.csv", "a")
	if hist then
		if newHistory then
			hist:write(FILES.HISTORY_HEADER .. "\n")
		end
		hist:write(table.concat({
			os.date("%Y-%m-%d %H:%M"), t.runs, t.bursts, string.format("%.1f", t.damage),
			t.hit and string.format("%.3f", t.hit) or "", t.kills, totals.metalKilled, t.lost, totals.metalLost
		}, ",") .. "\n")
		hist:close()
	end
	return FILES.EXPORT_DIR .. "sorties_" .. stamp .. ".csv"
end

-- Measured hit factor per target type and mode, against the Magpie Manual figure.
local function TargetTable()
	local agg = {}
	for i = 1, #runs do
		local run = runs[i]
		if #run.targets == 1 and run.bursts > run.wasted and (run.mode == "strafe" or run.mode == "loopback") then
			local key = run.targets[1] .. "/" .. run.mode
			agg[key] = agg[key] or {target = run.targets[1], mode = run.mode, bursts = 0, damage = 0, runs = 0}
			local a = agg[key]
			a.bursts, a.damage, a.runs = a.bursts + run.bursts - run.wasted, a.damage + run.damage, a.runs + 1
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
		Spring.GiveOrderToUnitArray(list, C.FIRE_STATE, {state}, 0)
	end
end

local function SetMode(list, mode)
	if C.LOOP_ATTACK and #list > 0 then
		Spring.GiveOrderToUnitArray(list, C.LOOP_ATTACK, {(mode == "loopback") and 1 or 0}, 0)
	end
end

-- The engine drops a move order whose point is off the map, so waypoints are kept inside it.
function C.InMap(x, z)
	local margin = 100
	return max(margin, min((Game.mapSizeX or x + margin) - margin, x)), max(margin, min((Game.mapSizeZ or z + margin) - margin, z))
end

-- Waypoints for an approach: the run starts the approach distance out on the chosen side of the target. A
-- Magpie on the far side goes round the target at that distance, the side with less known anti-air,
-- instead of flying over it on the way. Empty without an approach.
function C.ApproachRoute(px, pz, tx, tz, approach)
	if not (approach and px and tx) then
		return {}
	end
	local ux, uz -- from the target towards where the run comes from
	if approach.dx then
		ux, uz = -approach.dx, -approach.dz
	else
		ux, uz = approach.x - tx, approach.z - tz
		local d = sqrt(ux*ux + uz*uz)
		if d < 1 then
			ux, uz, d = 0, 1, 1
		end
		ux, uz = ux/d, uz/d
	end
	local dist = Opt('staging_distance')
	local sx, sz = C.InMap(tx + ux*dist, tz + uz*dist)
	local clear = 0.7*min(dist, Dist2D(tx, tz, sx, sz))
	if DistToSegment(tx, tz, px, pz, sx, sz) >= clear then
		return {{sx, sz}}
	end
	local a0 = math.atan2(pz - tz, px - tx)
	local turn = (math.atan2(sz - tz, sx - tx) - a0 + pi) % (2*pi) - pi
	local function Arc(delta)
		local steps = max(1, ceil(math.abs(delta)/(pi/4)))
		local route = {}
		for i = 1, steps - 1 do
			local a = a0 + delta*i/steps
			route[#route + 1] = {C.InMap(tx + cos(a)*dist, tz + sin(a)*dist)}
		end
		route[#route + 1] = {sx, sz}
		return route
	end
	local route = Arc(turn)
	if math.abs(turn) > pi/2 then
		-- More than a quarter turn round: the other way is further, but take it if it passes less known
		-- anti-air.
		local other = Arc(turn - 2*pi*(turn > 0 and 1 or -1))
		local function Risk(r)
			local total, x, z = 0, px, pz
			for i = 1, #r do
				total, x, z = total + RouteRisk(x, z, r[i][1], r[i][2]), r[i][1], r[i][2]
			end
			return total
		end
		if Risk(other) < Risk(route) - 1 then
			route = other
		end
	end
	return route
end

-- Flight a Magpie still has to make before it is on its way to (x, z): about a second to take off from the
-- ground or a pad, or the turn towards the point at a turning circle of about 110 elmos.
function C.Allowance(unitID, x, z)
	local ux, uy, uz = Spring.GetUnitPosition(unitID)
	if not ux then
		return 0
	end
	if uy - max(Spring.GetGroundHeight(ux, uz) or 0, 0) < 60 then
		return 250
	end
	local fx, _, fz = Spring.GetUnitDirection(unitID)
	local dx, dz = x - ux, z - uz
	local f, d = sqrt((fx or 0)^2 + (fz or 0)^2), sqrt(dx*dx + dz*dz)
	if f < 1e-6 or d < 1 then
		return 0
	end
	local angle = math.acos(max(-1, min(1, (fx*dx + fz*dz)/(f*d))))
	return 110*(angle - sin(angle))
end

-- Flight left from (x, z) through route[i..] to the target.
function C.PathFrom(x, z, route, i, tx, tz)
	local length = 0
	for j = i, #route do
		length = length + Dist2D(x, z, route[j][1], route[j][2])
		x, z = route[j][1], route[j][2]
	end
	return length + Dist2D(x, z, tx, tz)
end

-- A Magpie's flight to its group's target: the whole way for one still waiting, what is left for one on its
-- way (from the waypoint it is flying to). Nil for one that set off and was then given something else to do.
function C.Flight(unitID, group, waiting)
	local x, _, z = Spring.GetUnitPosition(unitID)
	local tx, _, tz = Spring.GetUnitPosition(group.target)
	if not (x and tx) then
		return nil
	end
	local route = group.routes and group.routes[unitID] or {}
	local i = 1
	if not waiting then
		-- Which waypoint it is on comes from its current order. Orders take a moment to arrive over the
		-- network, so a Magpie without its own orders yet has not set off. Once they have arrived, any other
		-- order came from the player or the game, and the Magpie no longer sets the pace.
		local cmdID, _, _, p1, _, p3 = Spring.GetUnitCurrentCommand(unitID)
		local ours = cmdID == C.ATTACK and p1 == group.target
		if ours then
			i = #route + 1
		elseif cmdID == C.MOVE and p3 then
			for j = 1, #route do
				if math.abs(route[j][1] - p1) < 1 and math.abs(route[j][2] - p3) < 1 then
					i, ours = j, true
				end
			end
		end
		local started = group.started and group.started[unitID]
		if ours and started then
			group.started[unitID] = true
		elseif started == true or (started and frame - started >= 90) then
			return nil
		end
	end
	local nx, nz = tx, tz
	if route[i] then
		nx, nz = route[i][1], route[i][2]
	end
	return C.PathFrom(x, z, route, i, tx, tz) + C.Allowance(unitID, nx, nz)
end

-- Send one Magpie of a group on its way: through its approach waypoints, if any, then the attack.
function C.Start(unitID, group)
	local route = group.routes and group.routes[unitID] or {}
	group.started = group.started or {}
	group.started[unitID] = frame
	C.Unhold(unitID)
	for i = 1, #route do
		local x, z = route[i][1], route[i][2]
		Spring.GiveOrderToUnit(unitID, C.MOVE, {x, Spring.GetGroundHeight(x, z) or 0, z}, i > 1 and C.OPT_SHIFT or 0)
	end
	Spring.GiveOrderToUnit(unitID, C.ATTACK, {group.target}, #route > 0 and C.OPT_SHIFT or 0)
end

-- Without fire discipline a Magpie holds fire only while it waits its turn: give its fire state back.
function C.Unhold(unitID)
	local mag = magpies[unitID]
	if mag and mag.savedFire ~= nil and not Opt('hold_fire') then
		Spring.GiveOrderToUnit(unitID, C.FIRE_STATE, {mag.savedFire}, 0)
		mag.savedFire = nil
	end
end

-- Take a Magpie out of its attack group, giving back its fire state.
function C.Drop(unitID)
	local mag = magpies[unitID]
	local group = mag and mag.group and groups[mag.group]
	if group then
		group.units[unitID] = nil
		if group.wait then
			group.wait[unitID] = nil
		end
	end
	if mag then
		mag.group = nil
		if mag.savedFire ~= nil then
			Spring.GiveOrderToUnit(unitID, C.FIRE_STATE, {mag.savedFire}, 0)
			mag.savedFire = nil
		end
	end
end

-- Arrive together: Magpies further out leave first. Each of the others waits where it is (on a pad, landed
-- or circling) until the furthest Magpie already on its way is no further from the target than it is,
-- across every group of the same Fire, so they all arrive at once. Revolver gives a waiting Magpie no
-- orders: once the launch's stop has reached it (its queue was seen empty, or after 3 s), any order other
-- than an attack the engine picked for it while idle came from the player or the game (a retreat to a
-- pad, say), and the Magpie leaves the attack. If the leaders stall, the rest go after the longest trip
-- time plus 8 s.
function C.Release(volley)
	local lead, longest, waiting = false, 0, {}
	for _, group in pairs(groups) do
		if group.volley == volley then
			for unitID in pairs(group.units) do
				if group.wait and group.wait[unitID] then
					local cmdID, cmdOpts = Spring.GetUnitCurrentCommand(unitID)
					if not cmdID or (cmdID == C.ATTACK and floor((cmdOpts or 0)/C.OPT_INTERNAL) % 2 == 1) then
						group.wait[unitID] = 2 -- the stop has reached it
					elseif group.wait[unitID] == 2 or frame - group.launchFrame >= 90 then
						C.Drop(unitID)
					end
					if group.wait and group.wait[unitID] then
						local length = C.Flight(unitID, group, true) or 0
						waiting[#waiting + 1] = {unitID, group, length}
						longest = max(longest, length)
					end
				else
					local left = C.Flight(unitID, group, false)
					if left and (not lead or left > lead) then
						lead = left
					end
				end
			end
		end
	end
	volley.deadline = volley.deadline or (frame + floor(30*longest/magpieStats.speed) + 30*8)
	local bar = (lead or longest) - 25
	for i = 1, #waiting do
		local unitID, group, length = waiting[i][1], waiting[i][2], waiting[i][3]
		if length >= bar or frame >= volley.deadline then
			group.wait[unitID] = nil
			C.Start(unitID, group)
		end
	end
	for _, group in pairs(groups) do
		if group.volley == volley and group.wait then
			for unitID in pairs(group.wait) do
				if not group.units[unitID] then
					group.wait[unitID] = nil -- lost, recalled or out of the attack some other way
				end
			end
			if not next(group.wait) then
				group.wait = nil
				group.phase = "attack"
			end
		end
	end
end

-- Say how many Magpies hold back, so a wing that does not all take off at once is no surprise.
function C.SayWaiting(launched)
	local waiting, total = 0, 0
	for i = 1, #launched do
		for unitID in pairs(launched[i].units) do
			total = total + 1
			if launched[i].wait and launched[i].wait[unitID] then
				waiting = waiting + 1
			end
		end
	end
	if waiting > 0 then
		Alert(waiting .. " of " .. C.Magpies(total) .. (waiting == 1 and " waits its turn" or " wait their turn") .. " so they all arrive together.")
	end
end

-- Attack the group's target straight away: no waiting, no approach (a new target after a kill, slow chain).
local function OrderAttack(group)
	group.wait, group.volley, group.routes, group.started = nil, nil, nil, nil
	group.phase = "attack"
	local list = UnitList(group.units)
	if #list == 0 then
		return
	end
	for i = 1, #list do
		C.Unhold(list[i])
	end
	Spring.GiveOrderToUnitArray(list, C.ATTACK, {group.target}, 0)
end

-- Send Magpies to a pad to land. The pad gadget refuses an unshifted REARM from a Magpie with full ammo
-- and health (a wing whose target died before it fired), but accepts a shift-queued one from any plane,
-- so the queue is cleared with STOP and REARM is queued behind it. Magpies already landing or headed
-- to a pad (noammo set) are left to the gadget.
local function SendHome(list)
	local sent, stranded = 0, 0
	for i = 1, #list do
		local unitID = list[i]
		local _, noAmmo = ReadAmmo(unitID)
		if noAmmo == 0 then
			local padID = next(pads) and ChoosePad(unitID)
			if padID then
				local mag = magpies[unitID]
				if mag then
					mag.pad, mag.homeFrame, mag.homeTries = padID, frame, 0
				end
				Spring.GiveOrderToUnit(unitID, CMD.STOP, {}, 0)
				Spring.GiveOrderToUnit(unitID, C.REARM, {padID}, C.OPT_SHIFT)
				sent = sent + 1
			else
				stranded = stranded + 1
			end
		end
	end
	if stranded > 0 then
		Alert(C.Magpies(stranded) .. (stranded == 1 and " has" or " have") .. " no pad to land on.", "nopad")
	end
	return sent
end

-- A Magpie sent home must be on its way within 1.5 s. If its landing order was dropped, send it again,
-- then fall back to flying it over the pad, and say so in the console.
function C.CheckHome(unitID, mag)
	if mag.noAmmo ~= 0 or mag.group then
		mag.homeFrame = nil
		return
	end
	if frame - mag.homeFrame < 45 then
		return
	end
	local cmdID = Spring.GetUnitCurrentCommand(unitID)
	if cmdID == C.REARM or cmdID == CMD.MOVE then
		return -- on its way
	end
	local padID = (mag.pad and pads[mag.pad]) and mag.pad or (next(pads) and ChoosePad(unitID))
	mag.homeTries = (mag.homeTries or 0) + 1
	mag.homeFrame = frame
	if padID and mag.homeTries <= 2 then
		Spring.Echo("Revolver: landing order for Magpie " .. unitID .. " was dropped (now " .. tostring(cmdID) .. "), sending it again.")
		mag.pad = padID
		Spring.GiveOrderToUnit(unitID, CMD.STOP, {}, 0)
		Spring.GiveOrderToUnit(unitID, C.REARM, {padID}, C.OPT_SHIFT)
	else
		local px, py, pz
		if padID then
			px, py, pz = Spring.GetUnitPosition(padID)
		end
		mag.homeFrame = nil
		if px then
			Alert("A pad would not take some Magpies; flying them back over it instead.", "padrefused")
			Spring.GiveOrderToUnit(unitID, CMD.MOVE, {px, py, pz}, 0)
		end
	end
end

local function ReleaseGroup(group, home)
	local list = UnitList(group.units)
	for i = 1, #list do
		local mag = magpies[list[i]]
		if mag then
			mag.group = nil
			if mag.savedFire ~= nil then
				Spring.GiveOrderToUnit(list[i], C.FIRE_STATE, {mag.savedFire}, 0)
				mag.savedFire = nil
			end
		end
	end
	if home and #list > 0 then
		local sent = SendHome(list)
		if sent > 0 then
			Alert("Wing " .. (WING_LETTER[group.wing] or "?") .. ": " .. (group.target and not IsAliveEnemy(group.target) and "target down, " or "") .. C.Magpies(sent) .. " heading to pads.")
		end
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
	local defID = Spring.GetUnitDefID(target)
	if Opt('auto_style') and defID then
		group.mode = AdviseMode(UnitDefs[defID].name, tonumber(Opt('horizon')))
		SetMode(UnitList(group.units), group.mode)
	end
	OrderAttack(group)
	Allies.Dispatch(target, #UnitList(group.units))
end

-- volley: the groups launched together, which arrive together. hand: an attack ordered by right-click, which
-- keeps each Magpie's own attack style.
local function LaunchGroup(list, target, queue, mode, approach, rotate, direct, volley, hand)
	local group = {
		id = nextGroupID, units = {}, target = target, queue = queue, mode = mode,
		approach = approach, rotate = rotate, launchFrame = frame,
	}
	nextGroupID = nextGroupID + 1
	-- Waiting Magpies hold fire even without fire discipline: one free to fire would go after anything near.
	local together = not direct and Opt(hand and 'hand_together' or 'time_on_target')
	local hold = Opt('hold_fire') or together
	local w
	for i = 1, #list do
		local mag = magpies[list[i]]
		group.units[list[i]] = true
		mag.group = group.id
		mag.state = "attacking"
		w = w or mag.wing
		if hold then
			if mag.savedFire == nil then
				local firestate = Spring.GetUnitStates(list[i], false)
				mag.savedFire = firestate or C.FREE
			end
		end
	end
	group.wing = w
	groups[group.id] = group
	Allies.Dispatch(target, #list)

	local run = NewRun(w, {target}, mode, true)
	run.magpies = #list
	for i = 1, #list do
		magpies[list[i]].run = run
	end
	group.run = run

	if not hand then
		SetMode(list, mode)
	end
	if hold then
		SetFireState(list, C.HOLD)
	end
	if direct then
		OrderAttack(group)
		return group
	end
	local tx, _, tz = Spring.GetUnitPosition(target)
	group.routes = {}
	if approach then
		for i = 1, #list do
			local x, _, z = Spring.GetUnitPosition(list[i])
			group.routes[list[i]] = C.ApproachRoute(x, z, tx, tz, approach)
		end
	end
	if together then
		-- Arrive together: nobody moves until C.Release says when. A Magpie busy with something else holds
		-- where it is meanwhile.
		group.volley = volley or {}
		group.wait = {}
		for i = 1, #list do
			group.wait[list[i]] = true
			if Spring.GetUnitCurrentCommand(list[i]) then
				Spring.GiveOrderToUnit(list[i], CMD.STOP, {}, 0)
			end
		end
		group.phase = "staging"
		if not volley then
			C.Release(group.volley)
		end
		return group
	end
	for i = 1, #list do
		C.Start(list[i], group)
	end
	group.phase = "attack"
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
		local defID = Spring.GetUnitDefID(target)
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
		local defID = Spring.GetUnitDefID(targets[i])
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
	local mx, my = Spring.GetMouseState()
	local kind, id = Spring.TraceScreenRay(mx, my)
	if kind == "unit" and IsAliveEnemy(id) and Spring.GetUnitDefID(id) then
		return id
	end
	return nil
end

local function HoveredGround()
	local mx, my = Spring.GetMouseState()
	local kind, pos = Spring.TraceScreenRay(mx, my, true)
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
	local volley = {}
	for i = 1, #plan do
		local p = plan[i]
		if #p.units > 0 then
			launched[#launched + 1] = LaunchGroup(p.units, p.target, targets, p.mode, approachPoint, rotate or Opt('rotate_fire'), false, volley)
		end
	end
	C.Release(volley)
	C.SayWaiting(launched)
	approachPoint = nil
	if shortfall > 0 then
		Alert("Short " .. C.Magpies(shortfall) .. " for the chosen kill time.")
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
			Spring.GiveOrderToUnit(list[i], C.FIRE_STATE, {mag.savedFire}, 0)
			mag.savedFire = nil
		end
	end
	if #list > 0 then
		SendHome(list)
	end
	return list
end

-- Shift or Ctrl adds the wing to the selection. So does a wing key pressed together with another one.
function SelectWing(w, add)
	if add == nil then
		local _, ctrl, _, shift = Spring.GetModKeyState()
		local now = Spring.GetTimer()
		add = shift or ctrl or (lastClick.keyTimer ~= nil and Spring.DiffTimers(now, lastClick.keyTimer) < 0.4)
		lastClick.keyTimer = now
	end
	local list = UnitList(wings[w].units)
	Spring.SelectUnitArray(list, add and true or false)
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
	Alert("Drag an arrow on the map the way the attack should fly over its target, or click where it should come in from. Right-click cancels.")
	return true
end

-- A pooled Magpie flying home waits beside its pad instead (circling, or landed next to it in the Land idle
-- mode), since landing on the pad throws away the ammo it has left.
function C.HoldNearPad(unitID, mag)
	local x, _, z = Spring.GetUnitPosition(unitID)
	local padID = (mag.pad and pads[mag.pad]) and mag.pad or (next(pads) and ChoosePad(unitID))
	local px, _, pz
	if padID then
		px, _, pz = Spring.GetUnitPosition(padID)
	end
	mag.homeFrame, mag.pad, mag.handTarget = nil, nil, nil
	if not (x and px) then
		Spring.GiveOrderToUnit(unitID, CMD.STOP, {}, 0)
		return
	end
	local d = Dist2D(x, z, px, pz)
	local hx, hz = px + 300, pz
	if d > 1 then
		hx, hz = px + (x - px)/d*300, pz + (z - pz)/d*300
	end
	hx, hz = C.InMap(hx, hz)
	Spring.GiveOrderToUnit(unitID, C.MOVE, {hx, Spring.GetGroundHeight(hx, hz) or 0, hz}, 0)
end

-- Pool: Magpies with ammo left, but too little to count as ready, move to wing F so the other wings stay
-- chambered. Pressed by hand it pools the selected Magpies (all of them if none are), keeps any flying home
-- in the air beside the pad, and says what it did. Wing F as the spare wing runs it every half second for
-- idle Magpies only. A pooled Magpie goes back to its own wing once it is rearmed (see C.Unpool).
function PoolPartial(byHand)
	local list = {}
	for _, unitID in ipairs(byHand and Spring.GetSelectedUnits() or {}) do
		if magpies[unitID] then
			list[#list + 1] = unitID
		end
	end
	if #list == 0 then
		list = UnitList(magpies)
	end
	local ready = Opt('ready_ammo')/100
	local cap = Opt('wing_size')*2
	local moved, kept, full = 0, 0, 0
	for i = 1, #list do
		local unitID = list[i]
		local mag = magpies[unitID]
		local homeward = byHand and mag.state == "returning"
		if mag.wing ~= WING_COUNT and not mag.group and mag.noAmmo == 0 and mag.ammo > 0 and mag.ammo < ready
				and (mag.state == "idle" or homeward) then
			if wings[WING_COUNT].count >= cap then
				full = full + 1
			else
				local from = mag.wing
				AddToWing(unitID, WING_COUNT)
				mag.poolFrom = from
				moved = moved + 1
				if homeward then
					C.HoldNearPad(unitID, mag)
					kept = kept + 1
				end
			end
		end
	end
	if byHand then
		local ammo = Opt('ready_ammo') .. "%"
		if moved > 0 then
			Alert("Pooled " .. C.Magpies(moved) .. " into wing F." .. (kept > 0 and (" " .. kept .. " flying home now " .. (kept == 1 and "waits" or "wait") .. " beside the pad with " .. (kept == 1 and "its" or "their") .. " ammo.") or "")
				.. (full > 0 and (" Wing F is full; " .. full .. " left out.") or ""))
		elseif full > 0 then
			Alert("Wing F is full; no Magpies pooled.")
		else
			Alert("Nothing to pool: a Magpie pools when it has some ammo left but under " .. ammo .. ", and is outside wing F and not in an attack.")
		end
	end
	return moved
end

-- A pooled Magpie rearmed to ready goes back to the wing it came from (or the next wing with room).
function C.Unpool(unitID, mag)
	if mag.poolFrom and mag.wing == WING_COUNT and mag.noAmmo == 0 and mag.ammo*100 >= Opt('ready_ammo') then
		local w = mag.poolFrom
		if w == WING_COUNT or wings[w].count >= Opt('wing_size') then
			w = PickWing()
		end
		AddToWing(unitID, w)
	elseif mag.poolFrom and mag.wing ~= WING_COUNT then
		mag.poolFrom = nil
	end
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
	calibration = {target = target, defID = Spring.GetUnitDefID(target)}
	Alert("Calibration on. Chambered wings will keep attacking this target.")
	return true
end

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- Update

local function UpdateMagpie(unitID, mag)
	local health, maxHealth = Spring.GetUnitHealth(unitID)
	if not health then
		return
	end
	local oldHealth = mag.health
	mag.health, mag.maxHealth = health, maxHealth or mag.maxHealth

	local oldAmmo, oldNoAmmo = mag.ammo, mag.noAmmo
	local ammo, noAmmo = ReadAmmo(unitID)
	mag.ammo, mag.noAmmo = ammo, noAmmo
	if noAmmo ~= oldNoAmmo then
		padQueue.frame = -1000 -- someone joined or left a pad queue
	end

	-- Repair on pads costs energy in proportion to health restored.
	if noAmmo == 3 and health > oldHealth then
		totals.repairEnergy = totals.repairEnergy + (health - oldHealth)*repairCostFactor*magpieStats.cost/mag.maxHealth
	end
	if oldNoAmmo ~= 2 and noAmmo == 2 then
		mag.rearmStart = frame
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
			Spring.GiveOrderToUnit(unitID, C.FIRE_STATE, {mag.savedFire}, 0)
			mag.savedFire = nil
		end
		if Opt('pad_balance') and next(pads) then
			local padID = ChoosePad(unitID)
			if padID then
				mag.pad = padID
				Spring.GiveOrderToUnit(unitID, C.REARM, {padID}, 0)
			end
		end
	elseif noAmmo == 0 and oldNoAmmo ~= 0 then
		mag.pad = nil
	end
	if noAmmo ~= 0 and not mag.pad then
		local cmdID, _, _, p1 = Spring.GetUnitCurrentCommand(unitID)
		if cmdID == C.REARM and p1 and pads[p1] then
			mag.pad = p1
		end
	end

	-- Attacks ordered by hand (not through Fire): remember which unit the Magpie is attacking. When it
	-- is left with nothing to do and that unit is dead, the target was killed: kill confirm sends it home.
	if not mag.group and noAmmo == 0 then
		local cmdID, _, _, p1, p2 = Spring.GetUnitCurrentCommand(unitID)
		if cmdID == C.ATTACK and p1 and not p2 then
			if mag.handTarget ~= p1 then
				Allies.Dispatch(p1, 1)
			end
			mag.handTarget = p1
		elseif cmdID then
			mag.handTarget = nil
		elseif mag.handTarget then
			if not IsAliveEnemy(mag.handTarget) and Opt('kill_confirm') ~= 'off' then
				C.killHome[#C.killHome + 1] = unitID
			end
			mag.handTarget = nil
		end
	end
	if mag.homeFrame then
		C.CheckHome(unitID, mag)
	end
	mag.state = ClassifyState(mag)
end

local function UpdateGroups()
	local chains = {} -- launched after the loop: adding groups while going through them is not allowed
	for id, group in pairs(groups) do
		-- Drop members that went home or died.
		for unitID in pairs(group.units) do
			local mag = magpies[unitID]
			if not mag or mag.group ~= id then
				group.units[unitID] = nil
				if group.wait then
					group.wait[unitID] = nil
				end
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
			if group.phase == "attack" then
				-- Fire discipline
				if Opt('hold_fire') and Opt('release_near_target') then
					for i = 1, #list do
						local mag = magpies[list[i]]
						local d = UnitDist2D(list[i], group.target)
						local want = (d and d <= magpieStats.range + 60) and C.FREE or C.HOLD
						if mag.fireNow ~= want then
							mag.fireNow = want
							Spring.GiveOrderToUnit(list[i], C.FIRE_STATE, {want}, 0)
						end
					end
				end
				-- Slow chain
				if Opt('slow_chain') and not group.slowChained and #list > 1 then
					local slow = Spring.GetUnitRulesParam(group.target, "slowState") or 0
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
							chains[#chains + 1] = {moving, nextTarget, group.queue, group.mode, group.rotate}
						end
					end
				end
			end
		end
	end
	for i = 1, #chains do
		local c = chains[i]
		LaunchGroup(c[1], c[2], c[3], c[4], nil, c[5], true)
	end
	-- Arrive together: start the Magpies whose turn has come, one Fire at a time.
	local released = {}
	for _, group in pairs(groups) do
		if group.wait and group.volley and not released[group.volley] then
			released[group.volley] = true
			C.Release(group.volley)
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
		local defID = Spring.ValidUnitID(unitID) and Spring.GetUnitDefID(unitID)
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
			elseif Spring.IsPosInLos(t.x, t.y, t.z, myAllyTeamID) and not Spring.ValidUnitID(unitID) then
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
	for unitID, mag in pairs(magpies) do
		if mag.poolFrom then
			C.Unpool(unitID, mag)
		end
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
		local tx, ty, tz = Spring.GetUnitPosition(target)
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
		local _, _, _, _, buildProgress = Spring.GetUnitHealth(unitID)
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
	-- Only reaches widgets for enemy units with full view (replays); players see enemy deaths through UpdateStruck.
	local s = struck[unitID]
	if s then
		local health = Spring.GetUnitHealth(unitID)
		if health then
			UpdateStruck()
		end
		if struck[unitID] then
			KillCredit(unitID, s)
		end
	end
end

function widget:UnitDamaged(unitID, unitDefID, unitTeam, damage, paralyzer, weaponDefID, projectileID, attackerID, attackerDefID, attackerTeam)
	if paralyzer or not damage then
		return
	end
	-- Players only hear about their own team's units here; damage Magpies deal is tracked in UpdateStruck.
	if not Spring.AreTeamsAllied(unitTeam, myTeamID) then
		return
	end
	if not (UnitDefs[unitDefID] and UnitDefs[unitDefID].canFly) then
		Allies.Hurt(unitID, unitTeam)
	end
	local shooter = attackerID and threats[attackerID]
	if shooter and aaDefs[shooter.defID].stockTime then
		ConsumeMissile(shooter)
	elseif not attackerID and magpies[unitID] then
		-- Hit from out of sight: a missile-sized hit came from the nearest stockpiler that reaches us.
		local x, _, z = Spring.GetUnitPosition(unitID)
		local best, bestD
		for _, t in pairs(threats) do
			local def = aaDefs[t.defID]
			if x and def.stockTime and damage >= def.stockShot*0.6 then
				local d = Dist2D(x, z, t.x, t.z)
				if d <= t.range + 100 and (not bestD or d < bestD) then
					best, bestD = t, d
				end
			end
		end
		if best then
			ConsumeMissile(best)
		end
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
	local defID = Spring.GetUnitDefID(unitID)
	if not defID then
		return
	end
	if AddThreat(unitID, defID) then
		-- New anti-air on the route of a wing on its way in?
		local t = threats[unitID]
		for gid, group in pairs(groups) do
			local tx, _, tz = Spring.GetUnitPosition(group.target)
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
		local track = Opt('ledger_tracking')
		for unitID, mag in pairs(magpies) do
			if track and mag.noAmmo == 0 then
				Watch(AimOf(mag)) -- health baseline before the burst lands
			end
			UpdateMagpie(unitID, mag)
		end
		if #C.killHome > 0 then
			local list = C.killHome
			C.killHome = {}
			local sent = SendHome(list)
			if sent > 0 then
				local w = magpies[list[1]] and magpies[list[1]].wing
				Alert((w and ("Wing " .. WING_LETTER[w] .. ": ") or "") .. "target down, " .. C.Magpies(sent) .. " heading to pads.")
			end
		end
		if track then
			UpdateStruck()
		end
		Allies.Flush()
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
		Allies.Update()
	end
end

function widget:AddConsoleLine(line)
	Allies.Heard(line)
end

-- A map point labelled !air places a request exactly.
function widget:MapDrawCmd(playerID, cmdType, x, y, z, label)
	if cmdType == "point" and type(label) == "string" and Opt('air_requests') and Allies.HasAir(label) then
		local name, _, spec, teamID, allyTeamID = Spring.GetPlayerInfo(playerID, false)
		if name and not spec and allyTeamID == myAllyTeamID then
			Allies.Request(playerID, name, teamID, label, x, z)
		end
	end
	return false
end

-- A right-click attack with Magpies selected goes through Revolver when an approach is set (the attack uses
-- it up) or Arrive together on right-click is on: the Magpies fly the approach if there is one, and with that
-- switch on the closer ones wait their turn as with Fire, each keeping its own attack style. The rest of the
-- selection, and Magpies with no ammo, get the order as given. Queued (shift) and modified clicks are left
-- alone.
function widget:CommandNotify(cmdID, params, opts)
	if cmdID ~= C.ATTACK or #params ~= 1 or not (approachPoint or Opt('hand_together')) then
		return false
	end
	if opts and (opts.shift or opts.ctrl or opts.alt or opts.meta) then
		return false
	end
	local target = params[1]
	if not (IsAliveEnemy(target) and Spring.GetUnitPosition(target)) then
		return false
	end
	local list, others = {}, {}
	for _, unitID in ipairs(Spring.GetSelectedUnits() or {}) do
		local mag = magpies[unitID]
		if mag and mag.noAmmo == 0 and mag.ammo > 0 then
			list[#list + 1] = unitID
		else
			others[#others + 1] = unitID
		end
	end
	if #list == 0 then
		return false
	end
	for i = 1, #list do
		-- Out of any earlier attack, keeping the fire state it had before that one (giving it back here
		-- would arrive after the new attack reads it)
		local mag = magpies[list[i]]
		local old = mag.group and groups[mag.group]
		if old then
			old.units[list[i]] = nil
			if old.wait then
				old.wait[list[i]] = nil
			end
		end
		mag.group, mag.handTarget = nil, nil
	end
	local group = LaunchGroup(list, target, {target}, MagpieMode(list[1]), approachPoint, false, false, nil, true)
	C.SayWaiting({group})
	approachPoint = nil
	if #others > 0 then
		Spring.GiveOrderToUnitArray(others, cmdID, params, opts and opts.coded or 0)
	end
	return true
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

function ResetSizes()
	SetOption('hud_size', 140)
	SetOption('ledger_size', 120)
	SetOption('requests_size', 100)
end

local ACTIONS = {
	revolver_fire = function() Fire() end,
	revolver_mark = function() Mark() end,
	revolver_clear = function() ClearMarks() end,
	revolver_recall = function() Recall() end,
	revolver_ready = function() SelectReady() end,
	revolver_approach = function() SetApproach() end,
	revolver_pool = function() PoolPartial(true) end,
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
	Spring.Echo("Revolver: build " .. ((widget.GetInfo and widget:GetInfo().version) or "?") .. " loaded.")
	myTeamID = Spring.GetMyTeamID()
	myAllyTeamID = Spring.GetMyAllyTeamID()
	frame = Spring.GetGameFrame()

	local units = Spring.GetTeamUnits(myTeamID) or {}
	for i = 1, #units do
		local unitID = units[i]
		local defID = Spring.GetUnitDefID(unitID)
		local _, _, _, _, buildProgress = Spring.GetUnitHealth(unitID)
		if (buildProgress or 1) >= 1 then
			widget:UnitFinished(unitID, defID, myTeamID)
		end
	end
	for _, teamID in ipairs(Spring.GetTeamList(myAllyTeamID) or {}) do
		if teamID ~= myTeamID then
			local allied = Spring.GetTeamUnits(teamID) or {}
			for i = 1, #allied do
				local defID = Spring.GetUnitDefID(allied[i])
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

function widget:GetConfigData()
	return {hudX = hud.fx, hudY = hud.fy, ledgerX = ledgerPanel.fx, ledgerY = ledgerPanel.fy,
		hudSize = options.hud_size.value, ledgerSize = options.ledger_size.value, menuX = menuPanel.fx, menuY = menuPanel.fy,
		requestsX = Allies.panel.fx, requestsY = Allies.panel.fy, requestsSize = options.requests_size.value}
end

function widget:SetConfigData(data)
	if type(data) ~= "table" then
		return
	end
	local function Fraction(v, default)
		v = tonumber(v)
		return (v and v >= 0 and v <= 1) and v or default
	end
	hud.fx, hud.fy = Fraction(data.hudX, HUD_DEFAULT.fx), Fraction(data.hudY, HUD_DEFAULT.fy)
	ledgerPanel.fx, ledgerPanel.fy = Fraction(data.ledgerX, LEDGER_DEFAULT.fx), Fraction(data.ledgerY, LEDGER_DEFAULT.fy)
	menuPanel.fx, menuPanel.fy = Fraction(data.menuX, 0.5), Fraction(data.menuY, 0.5)
	Allies.panel.fx, Allies.panel.fy = Fraction(data.requestsX, Allies.DEFAULT.fx), Fraction(data.requestsY, Allies.DEFAULT.fy)
	for key, saved in pairs({hud_size = data.hudSize, ledger_size = data.ledgerSize, requests_size = data.requestsSize}) do
		local v = tonumber(saved)
		if v and v >= options[key].min and v <= options[key].max then
			options[key].value = v
		end
	end
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
			Spring.GiveOrderToUnit(unitID, C.FIRE_STATE, {mag.savedFire}, 0)
		end
	end
	WG.Revolver = nil
end

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- Drawing

local CardLines
do

local GroundAt
local D = {} -- drawing helpers


local COLOR = {
	ready     = {0.67, 0.57, 1.0, 1},
	attacking = {0.95, 0.76, 0.36, 1},
	returning = {1.0, 0.50, 0.47, 1},
	pad       = {0.55, 0.78, 0.95, 1},
	idle      = {0.65, 0.63, 0.71, 1},
	empty     = {0.4, 0.4, 0.45, 0.6},
	text      = {0.94, 0.93, 0.97, 1},
	muted     = {0.66, 0.64, 0.73, 1},
	faint     = {0.48, 0.47, 0.55, 1},
	good      = {0.45, 0.86, 0.58, 1},
	panelTop  = {0.13, 0.13, 0.17, 0.93},
	panelBot  = {0.07, 0.07, 0.095, 0.93},
	edge      = {1, 1, 1, 0.10},
	shadow    = {0, 0, 0, 0.35},
	track     = {1, 1, 1, 0.08},
	grid      = {1, 1, 1, 0.07},
	tile      = {1, 1, 1, 0.045},
}

-- Outlined vector font when the engine provides one, plain gl.Text otherwise.
local font
local function Text(str, x, y, size, opts, c)
	c = c or COLOR.text
	if font == nil then
		local ok, f = pcall(gl.LoadFont, "FreeSansBold.otf", 40, 6, 4)
		font = (ok and (type(f) == "userdata" or type(f) == "table")) and f or false
	end
	if font then
		font:SetTextColor(c[1], c[2], c[3], c[4] or 1)
		font:SetOutlineColor(0, 0, 0, 0.8*(c[4] or 1))
		font:Print(str, x, y, size, opts)
	else
		gl.Color(c[1], c[2], c[3], c[4] or 1)
		gl.Text(str, x, y, size, opts)
	end
end

function D.TextWidth(str, size)
	local w = font and font:GetTextWidth(str) or (gl.GetTextWidth and gl.GetTextWidth(str))
	if type(w) ~= "number" then
		w = #str*0.55
	end
	return w*size
end

function D.Mix(a, b, f)
	return {a[1] + (b[1] - a[1])*f, a[2] + (b[2] - a[2])*f, a[3] + (b[3] - a[3])*f, (a[4] or 1) + ((b[4] or 1) - (a[4] or 1))*f}
end

function D.Alpha(c, a)
	return {c[1], c[2], c[3], a}
end

-- Rounded rectangle with a vertical gradient (top colour, bottom colour).
function D.RoundRect(x1, y1, x2, y2, r, top, bottom)
	bottom = bottom or top
	r = max(0, min(r, (x2 - x1)*0.5, (y2 - y1)*0.5))
	local function V(x, y)
		local f = (y2 > y1) and (y - y1)/(y2 - y1) or 0
		gl.Color(bottom[1] + (top[1] - bottom[1])*f, bottom[2] + (top[2] - bottom[2])*f, bottom[3] + (top[3] - bottom[3])*f,
			(bottom[4] or 1) + ((top[4] or 1) - (bottom[4] or 1))*f)
		gl.Vertex(x, y)
	end
	gl.BeginEnd(GL.TRIANGLE_FAN, function()
		V((x1 + x2)*0.5, (y1 + y2)*0.5)
		local corners = {{x2 - r, y2 - r, 0}, {x1 + r, y2 - r, 0.5*pi}, {x1 + r, y1 + r, pi}, {x2 - r, y1 + r, 1.5*pi}}
		for i = 1, 4 do
			local c = corners[i]
			for j = 0, 5 do
				local a = c[3] + j/5*0.5*pi
				V(c[1] + cos(a)*r, c[2] + sin(a)*r)
			end
		end
		V(x2, y2 - r)
	end)
end

function D.RoundOutline(x1, y1, x2, y2, r, c)
	r = max(0, min(r, (x2 - x1)*0.5, (y2 - y1)*0.5))
	gl.Color(c)
	gl.BeginEnd(GL.LINE_LOOP, function()
		local corners = {{x2 - r, y2 - r, 0}, {x1 + r, y2 - r, 0.5*pi}, {x1 + r, y1 + r, pi}, {x2 - r, y1 + r, 1.5*pi}}
		for i = 1, 4 do
			local c = corners[i]
			for j = 0, 5 do
				local a = c[3] + j/5*0.5*pi
				gl.Vertex(c[1] + cos(a)*r, c[2] + sin(a)*r)
			end
		end
	end)
end

-- Panel: soft shadow, gradient body, faint edge.
function D.Panel(x1, y1, x2, y2, r)
	D.RoundRect(x1 + 2, y1 - 4, x2 + 4, y2 - 2, r + 2, COLOR.shadow)
	D.RoundRect(x1, y1, x2, y2, r, COLOR.panelTop, COLOR.panelBot)
	D.RoundOutline(x1, y1, x2, y2, r, COLOR.edge)
end

-- Ring segment from 12 o'clock, clockwise, `fraction` of the way round.
function D.Arc(x, y, r1, r2, fraction, segments, c)
	if fraction <= 0 then
		return
	end
	fraction = min(1, fraction)
	local n = max(2, ceil(segments*fraction))
	gl.Color(c)
	gl.BeginEnd(GL.TRIANGLE_STRIP, function()
		for i = 0, n do
			local a = pi/2 - 2*pi*fraction*i/n
			local ca, sa = cos(a), sin(a)
			gl.Vertex(x + ca*r1, y + sa*r1)
			gl.Vertex(x + ca*r2, y + sa*r2)
		end
	end)
end

-- Disc with a radial gradient.
function D.Disc(x, y, r, segments, inner, outer)
	gl.BeginEnd(GL.TRIANGLE_FAN, function()
		gl.Color(inner)
		gl.Vertex(x, y)
		gl.Color(outer or inner)
		for i = 0, segments do
			local a = 2*pi*i/segments
			gl.Vertex(x + cos(a)*r, y + sin(a)*r)
		end
	end)
end

-- Text on a rounded pill, centred on x.
function D.Pill(str, x, y, size, c, bg)
	local w = D.TextWidth(str, size) + size*1.2
	local h = size*1.6
	D.RoundRect(x - w*0.5, y - h*0.5, x + w*0.5, y + h*0.5, h*0.5, bg or {0.07, 0.07, 0.09, 0.85})
	Text(str, x, y, size, "cv", c)
	return w, h
end

function D.UiScale()
	local _, vsy = Spring.GetViewGeometry()
	return max(0.75, vsy/1080)
end

-- Cylinder geometry at its current size.
function D.HudGeometry()
	local k = D.UiScale()*Opt('hud_size')/100
	hud.scale = k
	hud.radius = 92*k
	hud.chamber = 0.27*hud.radius
	hud.ring = 0.63*hud.radius
	hud.hub = 0.21*hud.radius
	return k
end

local function ChamberCentre(w)
	D.HudGeometry()
	local vsx, vsy = Spring.GetViewGeometry()
	-- Kept whole on screen whatever its size
	local R = hud.radius
	local cx, cy = max(R, min(vsx - R, vsx*hud.fx)), max(R, min(vsy - R, vsy*hud.fy))
	local angle = pi/2 - (w - 1)*pi/3
	return cx + cos(angle)*hud.ring, cy + sin(angle)*hud.ring, cx, cy
end

-- Selection, kept by SelectionChanged; flight path card state.
local view = {selected = {}, selSet = {}, path = nil, hoverHub = false}

local function WingSelected(w)
	for unitID in pairs(wings[w].units) do
		if view.selSet[unitID] then
			return true
		end
	end
	return false
end

local function DrawCylinder()
	local _, _, cx, cy = ChamberCentre(1)
	local R, k = hud.radius, hud.scale
	-- Body
	D.Disc(cx + 3*k, cy - 4*k, R + 3*k, 64, COLOR.shadow, {0, 0, 0, 0})
	D.Disc(cx, cy, R, 64, {0.15, 0.15, 0.19, 0.92}, {0.06, 0.06, 0.08, 0.92})
	D.Arc(cx, cy, R - 1.5*k, R, 1, 64, COLOR.edge)

	for w = 1, WING_COUNT do
		local x, y = ChamberCentre(w)
		local cr = hud.chamber
		local s = WingSummary(w)
		local stateColor = COLOR[s.state] or COLOR.idle
		local selected = WingSelected(w)
		if s.chambered and s.n > 0 then
			D.Arc(x, y, cr*1.02, cr*1.16, 1, 40, D.Alpha(COLOR.ready, 0.28))
		end
		if selected then
			D.Arc(x, y, cr*1.04, cr*1.12, 1, 40, {1, 1, 1, 0.9})
		end
		local inner = s.n > 0 and D.Mix({0.22, 0.22, 0.28, 0.97}, stateColor, 0.18) or {0.16, 0.16, 0.2, 0.9}
		D.Disc(x, y, cr, 40, inner, {0.11, 0.11, 0.14, 0.97})
		-- Ammo ring, health ring inside it
		D.Arc(x, y, cr*0.80, cr*0.95, 1, 40, COLOR.track)
		if s.n > 0 then
			D.Arc(x, y, cr*0.80, cr*0.95, s.ammo, 40, stateColor)
			D.Arc(x, y, cr*0.70, cr*0.76, 1, 40, COLOR.track)
			D.Arc(x, y, cr*0.70, cr*0.76, s.health, 40, D.Mix(COLOR.returning, COLOR.good, max(0, min(1, (s.health - 0.3)/0.6))))
		end
		Text(WING_LETTER[w], x, y + cr*0.2, cr*0.58, "cvo", s.n > 0 and COLOR.text or COLOR.faint)
		local sub
		if s.n == 0 then
			sub = "empty"
		elseif s.state == "pad" or s.state == "returning" then
			sub = s.n .. " · " .. ceil(WingETA(w)) .. "s"
		else
			sub = s.n .. " · " .. floor(s.ammo*100 + 0.5) .. "%"
		end
		Text(sub, x, y - cr*0.32, cr*0.29, "cvo", s.n > 0 and COLOR.muted or COLOR.faint)
	end

	-- Hub: Magpies ready to launch; click for the menu.
	local pool = 0
	for wi = 1, WING_COUNT do
		local s = WingSummary(wi)
		if s.chambered then
			pool = pool + s.n
		end
	end
	D.Disc(cx, cy, hud.hub, 32, view.hoverHub and {0.27, 0.25, 0.36, 0.97} or {0.2, 0.2, 0.25, 0.97}, {0.12, 0.12, 0.15, 0.97})
	D.Arc(cx, cy, hud.hub - 1.2*k, hud.hub, 1, 32, COLOR.edge)
	Text(tostring(pool), cx, cy + hud.hub*0.18, hud.hub*0.62, "cvo", pool > 0 and COLOR.ready or COLOR.faint)
	Text("menu", cx, cy - hud.hub*0.45, hud.hub*0.30, "cvo", COLOR.muted)

	if Opt('fleet_advisor') then
		local plan = PadPlan()
		local short = plan.need > plan.slots
		D.Pill(string.format("Fleet %d · pad slots %d, need %d", plan.fleet, plan.slots, plan.need), cx, cy - R - 13*k, 10.5*k,
			short and COLOR.returning or COLOR.muted)
	end
	local shown = 0
	for i = #alerts, 1, -1 do
		local a = alerts[i]
		local age = frame - a.frame
		if age < 30*8 and shown < 3 then
			local fade = min(1, (30*8 - age)/45)
			D.Pill(a.text, cx, cy + R + 14*k + shown*20*k, 10.5*k, D.Alpha(COLOR.text, fade), {0.07, 0.07, 0.09, 0.85*fade})
			shown = shown + 1
		end
	end
	gl.Color(1, 1, 1, 1)
end

-- Breakpoint card lines; `cells` is the kill table as {label, strafe, loopback} rows (lines 2 to 2 + #cells).
function CardLines(target)
	local defID = Spring.GetUnitDefID(target)
	local ud = defID and UnitDefs[defID]
	if not ud then
		return nil
	end
	local lines = {ud.humanName or ud.name}
	local cells
	local entryS = BreakpointEntry(ud.name, "strafe")
	if entryS then
		cells = {}
		local function cell(mode, p)
			local entry = BreakpointEntry(ud.name, mode)
			local v = entry and entry.slow[p]
			return v and (v[1] .. " (lose " .. v[2] .. ")") or "no"
		end
		lines[#lines + 1] = "Kill within     Strafe        Loopback"
		cells[1] = {"Kill within", "Strafe", "Loopback"}
		local labels = {[1] = "1 pass", [2] = "2 passes", [3] = "3 passes", [5] = "5 passes", [99] = "1 sortie"}
		for i = 1, #defs.passes do
			local p = defs.passes[i]
			lines[#lines + 1] = string.format("%-15s %-13s %s", labels[p], cell("strafe", p), cell("loopback", p))
			cells[#cells + 1] = {labels[p], cell("strafe", p), cell("loopback", p)}
		end
	end
	local horizon = tonumber(Opt('horizon'))
	local mode = AdviseMode(ud.name, horizon)
	local need, lost, used, source = Need(target, mode, horizon)
	local slow = Spring.GetUnitRulesParam(target, "slowState") or 0
	lines[#lines + 1] = string.format("Now: %s, %d Magpies%s (%s)%s", mode == "loopback" and "Loopback" or "Strafe", need,
		(lost and lost > 0) and (", lose " .. lost) or "", source == "table" and "Magpie Manual" or "estimate",
		slow > 0.01 and string.format(", slowed %d%%", floor(slow*100)) or "")

	local tx, _, tz = Spring.GetUnitPosition(target)
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
	return lines, cells
end

-- Card next to the cursor: title, optional table, then lines. Returns its height.
local function DrawCardAt(x, top, title, cells, lines, k, lineColors)
	local size = 12*k
	local rowH = 16*k
	local w = 340*k
	local h = 30*k + (cells and (#cells*rowH + 8*k) or 0) + #lines*rowH + 6*k
	local vsx = Spring.GetViewGeometry()
	if x + w > vsx - 8 then
		x = x - w - 48*k
	end
	if top - h < 8 then
		top = h + 8
	end
	D.Panel(x, top - h, x + w, top, 6*k)
	Text(title, x + 10*k, top - 18*k, 14*k, "vo", COLOR.text)
	local y = top - 30*k
	if cells then
		local col = {x + 10*k, x + 110*k, x + 225*k}
		for i = 1, #cells do
			local c = cells[i]
			y = y - rowH
			if i == 1 then
				D.RoundRect(x + 6*k, y - 3*k, x + w - 6*k, y + rowH - 3*k, 3*k, COLOR.tile)
			end
			for j = 1, 3 do
				local color = (i == 1 or j == 1) and COLOR.muted or (c[j] == "no" and COLOR.faint or COLOR.text)
				Text(c[j], col[j], y + rowH*0.35, size*(i == 1 and 0.9 or 1), "vo", color)
			end
		end
		y = y - 8*k
	end
	for i = 1, #lines do
		y = y - rowH
		Text(lines[i], x + 10*k, y + rowH*0.35, size, "vo", (lineColors and COLOR[lineColors[i]]) or COLOR.muted)
	end
	gl.Color(1, 1, 1, 1)
	return h
end

local function DrawCard()
	local target = HoveredEnemy()
	if not target then
		return 0
	end
	local lines, cells = CardLines(target)
	if not lines then
		return 0
	end
	local rest = {}
	for i = 2 + (cells and #cells or 0), #lines do
		rest[#rest + 1] = lines[i]
	end
	local mx, my = Spring.GetMouseState()
	local k = D.UiScale()
	return DrawCardAt(mx + 24*k, my - 12*k, lines[1], cells, rest, k)
end

-- Ledger layout at its current size: x, top, width, height, scale.
function D.LedgerScale()
	local k = D.UiScale()*Opt('ledger_size')/100
	ledgerPanel.scale = k
	return k
end

local function LedgerRect()
	local vsx, vsy = Spring.GetViewGeometry()
	local k = D.LedgerScale()
	local h = ledgerPanel.h
	if #history > 0 and Opt('career_history') then
		h = h + 14
	end
	if Opt('fleet_advisor') then
		h = h + 14 + 12*#(FleetAdvice())
	end
	local w = ledgerPanel.w*k
	h = h*k
	return max(0, min(vsx - w, vsx*ledgerPanel.fx)), max(h, min(vsy, vsy*ledgerPanel.fy)), w, h, k
end

function D.Tile(x, y, w, h, k, label, value, note, valueColor)
	D.RoundRect(x, y - h, x + w, y, 4*k, COLOR.tile)
	Text(label, x + 7*k, y - 9*k, 8.5*k, "vo", COLOR.muted)
	Text(value, x + 7*k, y - 23*k, 15*k, "vo", valueColor or COLOR.text)
	if note then
		Text(note, x + 7*k, y - 36*k, 8*k, "vo", COLOR.faint)
	end
end

function D.Kilo(v)
	if v >= 10000 then
		return string.format("%.0fk", v/1000)
	elseif v >= 1000 then
		return string.format("%.1fk", v/1000)
	end
	return tostring(floor(v))
end

local function DrawLedger()
	local x, y, w, h, k = LedgerRect()
	D.Panel(x, y - h, x + w, y, 7*k)
	local t = GameTotals()
	local view = Opt('ledger_view')

	-- Title bar with view tabs
	Text("Revolver ledger", x + 10*k, y - 15*k, 13*k, "vo", COLOR.text)
	local tabs = {{'runs', "Runs"}, {'targets', "Targets"}}
	local tx = x + w - 8*k
	for i = #tabs, 1, -1 do
		local tw = D.TextWidth(tabs[i][2], 10*k) + 14*k
		local active = view == tabs[i][1]
		D.RoundRect(tx - tw, y - 23*k, tx, y - 7*k, 8*k, active and D.Alpha(COLOR.ready, 0.85) or COLOR.tile)
		Text(tabs[i][2], tx - tw*0.5, y - 15*k, 10*k, "cv", active and {0.08, 0.06, 0.15, 1} or COLOR.muted)
		tx = tx - tw - 4*k
	end

	-- Stat tiles
	local tileY, tileH, gap = y - 30*k, 42*k, 6*k
	local tileW = (w - 20*k - 3*gap)/4
	local expectedAll, en = 0, 0
	for i = 1, #runs do
		local e = ExpectedHitFactor(runs[i])
		if e and runs[i].bursts > runs[i].wasted then
			expectedAll, en = expectedAll + e, en + 1
		end
	end
	local hitColor = COLOR.text
	if t.hit and en > 0 then
		hitColor = (t.hit >= expectedAll/en*0.9) and COLOR.good or COLOR.attacking
	end
	D.Tile(x + 10*k, tileY, tileW, tileH, k, "HIT RATE", t.hit and string.format("%d%%", floor(t.hit*100 + 0.5)) or "-",
		en > 0 and string.format("manual %d%%", floor(expectedAll/en*100 + 0.5)) or "no aimed bursts", hitColor)
	D.Tile(x + 10*k + (tileW + gap), tileY, tileW, tileH, k, "KILLS", tostring(t.kills), D.Kilo(totals.metalKilled) .. " metal")
	local trade = totals.metalLost > 0 and totals.metalKilled/totals.metalLost or nil
	D.Tile(x + 10*k + 2*(tileW + gap), tileY, tileW, tileH, k, "TRADE", trade and string.format("%.1fx", trade) or "-",
		"lost " .. t.lost .. " (" .. D.Kilo(totals.metalLost) .. ")", trade and (trade >= 1 and COLOR.good or COLOR.returning) or COLOR.text)
	local wasted = 0
	for i = 1, #runs do
		wasted = wasted + runs[i].wasted
	end
	D.Tile(x + 10*k + 3*(tileW + gap), tileY, tileW, tileH, k, "BURSTS", D.Kilo(t.bursts),
		t.bursts > 0 and string.format("%d%% out of range", floor(wasted/t.bursts*100 + 0.5)) or (t.runs .. " runs"))

	-- Chart
	local gx, gw = x + 34*k, w - 46*k
	local gy, gh = y - 196*k, 108*k
	if view == 'runs' then
		for i = 0, 4 do
			local ly = gy + gh*i/4
			gl.Color(COLOR.grid)
			gl.Rect(gx, ly, gx + gw, ly + max(1, k))
			Text(string.format("%d%%", i*25), gx - 5*k, ly, 8*k, "rv", COLOR.faint)
		end
		local first = max(1, #runs - 19)
		local slot = gw/max(10, #runs - first + 1)
		local avg = {}
		local any = false
		for i = first, #runs do
			local run = runs[i]
			local hit = RunHitFactor(run)
			local px = gx + (i - first)*slot + slot*0.5
			if hit then
				any = true
				local c = run.mode == "loopback" and COLOR.attacking or COLOR.ready
				D.RoundRect(px - slot*0.32, gy, px + slot*0.32, gy + max(2*k, min(1, hit)*gh), 2*k, c, D.Alpha(c, 0.55))
				-- rolling average of the last five measured runs
				local sum, n = 0, 0
				for j = i, max(first, i - 4), -1 do
					local hj = RunHitFactor(runs[j])
					if hj then
						sum, n = sum + hj, n + 1
					end
				end
				avg[#avg + 1] = {px, gy + min(1, sum/n)*gh}
			end
			local expected = ExpectedHitFactor(run)
			if expected then
				gl.Color(COLOR.text)
				gl.Rect(px - slot*0.45, gy + expected*gh - k, px + slot*0.45, gy + expected*gh + k)
			end
			Text(WING_LETTER[run.wing] or "-", px, gy - 7*k, 7.5*k, "cv", COLOR.faint)
		end
		if #avg > 1 then
			gl.LineWidth(2*k)
			gl.Color(1, 1, 1, 0.75)
			gl.BeginEnd(GL.LINE_STRIP, function()
				for i = 1, #avg do
					gl.Vertex(avg[i][1], avg[i][2])
				end
			end)
			gl.LineWidth(1)
		end
		if not any then
			Text(#runs == 0 and "No runs yet. A bar appears for each sortie once Magpies fire."
				or "No aimed bursts measured yet.", gx + gw*0.5, gy + gh*0.5, 10*k, "cvo", COLOR.muted)
		end
		-- Legend
		local lx, ly = gx, gy - 20*k
		local function Key(c, label, bar)
			if bar then
				D.RoundRect(lx, ly - 4*k, lx + 8*k, ly + 4*k, 2*k, c)
			else
				gl.Color(c)
				gl.Rect(lx, ly - k, lx + 10*k, ly + k)
			end
			Text(label, lx + 13*k, ly, 8.5*k, "vo", COLOR.muted)
			lx = lx + 13*k + D.TextWidth(label, 8.5*k) + 12*k
		end
		Key(COLOR.ready, "Strafe", true)
		Key(COLOR.attacking, "Loopback", true)
		Key(COLOR.text, "Magpie Manual")
		Key({1, 1, 1, 0.75}, "Average of 5")
	else
		-- Hit rate per target type and style: bar measured, tick from the Magpie Manual.
		local list = TargetTable()
		local rows = min(6, #list)
		if rows == 0 then
			Text("No single-target runs yet.", gx + gw*0.5, gy + gh*0.5, 10*k, "cvo", COLOR.muted)
		end
		local rowH = gh/6
		local labelW = 112*k
		for i = 1, rows do
			local a = list[i]
			local ry = gy + gh - rowH*i
			local entry = BreakpointEntry(a.target, a.mode)
			local name = entry and entry.name or a.target
			Text(string.format("%s %s", name, a.mode == "loopback" and "(L)" or "(S)"), gx - 24*k, ry + rowH*0.5, 9*k, "vo", COLOR.muted)
			local bx, bw = gx + labelW - 24*k, gw - labelW - 26*k
			local c = a.mode == "loopback" and COLOR.attacking or COLOR.ready
			D.RoundRect(bx, ry + 2*k, bx + bw, ry + rowH - 2*k, 2*k, COLOR.tile)
			D.RoundRect(bx, ry + 2*k, bx + bw*min(1, a.measured), ry + rowH - 2*k, 2*k, c, D.Alpha(c, 0.6))
			gl.Color(COLOR.text)
			gl.Rect(bx + bw*a.expected - k, ry, bx + bw*a.expected + k, ry + rowH)
			Text(string.format("%d%% / %d%%", floor(a.measured*100 + 0.5), floor(a.expected*100 + 0.5)), bx + bw + 4*k, ry + rowH*0.5, 8.5*k, "vo", COLOR.muted)
		end
		Text("Bar: measured.  Tick: Magpie Manual.", gx, gy - 20*k, 8.5*k, "vo", COLOR.faint)
	end

	local ly = gy - 36*k
	if calibration then
		local list = CalibrationTable()
		local a = list[1]
		if a then
			Text(string.format("Calibrating %s %s: %d%% vs %d%% (%d runs)", a.target, a.mode, floor(a.measured*100 + 0.5), floor(a.expected*100 + 0.5), a.runs),
				x + w - 10*k, ly + 16*k, 8.5*k, "rvo", COLOR.attacking)
		end
	end
	if #history > 0 and Opt('career_history') then
		local sum, n = 0, 0
		for i = max(1, #history - 9), #history do
			sum, n = sum + history[i].hit, n + 1
		end
		Text(string.format("Last %d games: hit rate %d%%", n, floor(sum/n*100 + 0.5)), x + 10*k, ly, 9*k, "vo", COLOR.muted)
		ly = ly - 14*k
	end
	if Opt('fleet_advisor') then
		gl.Color(COLOR.grid)
		gl.Rect(x + 10*k, ly + 6*k, x + w - 10*k, ly + 6*k + max(1, k))
		local lines = FleetAdvice()
		for i = 1, #lines do
			Text(lines[i], x + 10*k, ly - 12*k*(i - 1) - 4*k, 9*k, "vo", (i == 3 and lines[i]:find("^Short")) and COLOR.returning or COLOR.muted)
		end
	end
	gl.Color(1, 1, 1, 1)
end

-- Air request panel: allies asking for Magpies, newest first.

function Allies.Visible()
	return Opt('air_requests') and #Allies.requests > 0
end

function Allies.Layout()
	local vsx, vsy = Spring.GetViewGeometry()
	local k = D.UiScale()*Opt('requests_size')/100
	local w, headH, rowH = 270*k, 26*k, 34*k
	local shown = min(#Allies.requests, 5)
	local more = #Allies.requests - shown
	local h = headH + shown*rowH + (more > 0 and 16*k or 0) + 6*k
	-- Kept whole on screen
	local x = floor(max(0, min(vsx - w, vsx*Allies.panel.fx)))
	local top = floor(max(min(h, vsy), min(vsy, vsy*Allies.panel.fy)))
	local rows = {}
	for i = 1, shown do
		local y2 = top - headH - (i - 1)*rowH
		rows[i] = {req = Allies.requests[i], y1 = y2 - rowH, y2 = y2}
	end
	return rows, x, top, w, h, k, more
end

-- Resize grip: the panel's lower right corner.
function Allies.GripRect(x, top, w, h, k)
	return x + w - 14*k, top - h, x + w, top - h + 14*k
end

function Allies.Grip()
	local _, x, top, w, h, k = Allies.Layout()
	return Allies.GripRect(x, top, w, h, k)
end

function Allies.Draw()
	local rows, x, top, w, h, k, more = Allies.Layout()
	local mx, my = Spring.GetMouseState()
	local gx1, _, _, gy2 = Allies.GripRect(x, top, w, h, k)
	local onGrip = (dragging and dragging.resize == 'requests') or (mx >= gx1 and mx <= x + w and my >= top - h and my <= gy2)
	D.Panel(x, top - h, x + w, top, 6*k)
	Text("Air requests", x + 10*k, top - 13*k, 12*k, "vo", COLOR.text)
	Text("click to look, x to dismiss", x + w - 10*k, top - 13*k, 8.5*k, "rvo", COLOR.faint)
	for i = 1, #rows do
		local r = rows[i]
		local req = r.req
		local over = not onGrip and mx >= x and mx <= x + w and my >= r.y1 and my < r.y2
		local overCross = over and mx >= x + w - 28*k
		gl.Color(COLOR.grid)
		gl.BeginEnd(GL.LINES, function()
			gl.Vertex(x + 8*k, r.y2)
			gl.Vertex(x + w - 8*k, r.y2)
		end)
		if over and not overCross then
			D.RoundRect(x + 4*k, r.y1 + k, x + w - 4*k, r.y2 - k, 4*k, COLOR.tile)
		end
		local age = floor(max(0, frame - req.frame)/30)
		local tint = req.answered and COLOR.good or COLOR.attacking
		Text(req.name, x + 10*k, r.y2 - 11*k, 11*k, "vo", tint)
		Text(req.where .. " · " .. string.format("%d:%02d", floor(age/60), age % 60), x + w - 30*k, r.y2 - 11*k, 9*k, "rvo", COLOR.muted)
		if req.note ~= "" then
			Text(req.note, x + 10*k, r.y1 + 10*k, 9*k, "vo", COLOR.text)
		end
		Text(req.answered and "answered" or req.source, x + w - 30*k, r.y1 + 10*k, 8.5*k, "rvo", req.answered and COLOR.good or COLOR.faint)
		-- Dismiss
		local cx, cy, d = x + w - 15*k, (r.y1 + r.y2)*0.5, 3.5*k
		if overCross then
			D.Disc(cx, cy, 8*k, 16, D.Alpha(COLOR.returning, 0.25))
		end
		gl.Color(overCross and COLOR.returning or COLOR.muted)
		gl.LineWidth(1.5*k)
		gl.BeginEnd(GL.LINES, function()
			gl.Vertex(cx - d, cy - d); gl.Vertex(cx + d, cy + d)
			gl.Vertex(cx - d, cy + d); gl.Vertex(cx + d, cy - d)
		end)
		gl.LineWidth(1)
	end
	if more > 0 then
		Text("+" .. more .. " older", x + 10*k, top - 26*k - #rows*34*k - 8*k, 8.5*k, "vo", COLOR.faint)
	end
	gl.Color(1, 1, 1, 1)
end

-- 'dismiss' or 'row' with its request, 'panel' elsewhere on the panel, nil off it.
function Allies.Hit(mx, my)
	if not Allies.Visible() then
		return nil
	end
	local rows, x, top, w, h, k = Allies.Layout()
	if mx < x or mx > x + w or my > top or my < top - h then
		return nil
	end
	for i = 1, #rows do
		local r = rows[i]
		if my >= r.y1 and my < r.y2 then
			return (mx >= x + w - 28*k) and 'dismiss' or 'row', r.req
		end
	end
	return 'panel'
end

function Allies.Click(part, req)
	if part == 'dismiss' then
		Allies.Remove(req.pid)
	elseif part == 'row' then
		Spring.SetCameraTarget(req.x, Spring.GetGroundHeight(req.x, req.z) or 0, req.z, 0.5)
	end
end

-- In-game feature menu

local function MenuLayout()
	local vsx, vsy = Spring.GetViewGeometry()
	local k = D.UiScale()
	local rows = {}
	for i = 1, #MENU do
		rows[#rows + 1] = {header = MENU[i].title}
		for j = 1, #MENU[i].keys do
			rows[#rows + 1] = {key = MENU[i].keys[j]}
		end
	end
	rows[#rows + 1] = {close = true}
	local rowH = min(20*k, (vsy - 36*k)/#rows) -- rows shrink to fit short screens
	local w = 440*k
	local h = #rows*rowH + 36*k
	-- Kept whole on screen
	local x = floor(max(0, min(vsx - w, vsx*menuPanel.fx - w*0.5)))
	local top = floor(max(min(h, vsy), min(vsy, vsy*menuPanel.fy + h*0.5)))
	for i = 1, #rows do
		rows[i].y1 = top - 30*k - i*rowH
		rows[i].y2 = rows[i].y1 + rowH
	end
	return rows, x, top, w, h, k
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
	local rows, x, top, w, h, k = MenuLayout()
	local mx, my = Spring.GetMouseState()
	D.Panel(x, top - h, x + w, top, 8*k)
	Text("Revolver features", x + 12*k, top - 17*k, 14*k, "vo", COLOR.text)
	Text("drag here to move, click a row to change", x + w - 12*k, top - 17*k, 9*k, "rvo", COLOR.faint)
	for i = 1, #rows do
		local r = rows[i]
		local midY = (r.y1 + r.y2)*0.5
		local hover = mx >= x and mx <= x + w and my >= r.y1 and my < r.y2
		if r.header then
			Text(string.upper(r.header), x + 12*k, midY, 9.5*k, "vo", COLOR.attacking)
		elseif r.close then
			D.RoundRect(x + w*0.5 - 40*k, r.y1 + 2*k, x + w*0.5 + 40*k, r.y2 - 2*k, 8*k, hover and D.Alpha(COLOR.ready, 0.5) or COLOR.tile)
			Text("Close", x + w*0.5, midY, 10.5*k, "cv", COLOR.text)
		else
			if hover then
				D.RoundRect(x + 6*k, r.y1 + k, x + w - 6*k, r.y2 - k, 4*k, COLOR.tile)
			end
			local option = options[r.key]
			Text(option.name, x + 24*k, midY, 10.5*k, "vo", COLOR.text)
			if option.type == 'bool' then
				-- Toggle switch
				local sx, sw, sh = x + w - 46*k, 30*k, 14*k
				local on = option.value
				D.RoundRect(sx, midY - sh*0.5, sx + sw, midY + sh*0.5, sh*0.5, on and D.Alpha(COLOR.ready, 0.9) or {0.3, 0.3, 0.36, 0.9})
				local kx = on and (sx + sw - sh*0.5) or (sx + sh*0.5)
				D.Disc(kx, midY, sh*0.38, 16, {1, 1, 1, 1})
			else
				Text(OptionText(r.key), x + w - 14*k, midY, 10*k, "rvo", COLOR.ready)
			end
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

-- Flight path card: what a straight flight from the selected Magpies to the cursor crosses.
local PATH_COMMANDS = {[CMD.MOVE or -1] = true, [customCmds.RAW_MOVE or -1] = true, [CMD.ATTACK or -1] = true,
	[CMD.FIGHT or -1] = true, [CMD.PATROL or -1] = true, [CMD.AREA_ATTACK or -1] = true}

local function SelectedMagpies()
	local list = {}
	for i = 1, #view.selected do
		if magpies[view.selected[i]] then
			list[#list + 1] = view.selected[i]
		end
	end
	return list
end

local function UpdatePathView()
	view.path = nil
	local mode = Opt('path_card')
	if mode == 'off' or not Opt('threat_map') then
		return
	end
	if mode == 'command' then
		local _, cmdID = Spring.GetActiveCommand()
		if not (cmdID and PATH_COMMANDS[cmdID]) then
			return
		end
	end
	local list = SelectedMagpies()
	if #list == 0 then
		return
	end
	local mx, my = Spring.GetMouseState()
	if widget:IsAbove(mx, my) then
		return
	end
	local gx, gz = GroundAt(mx, my)
	local sx, sz = Centroid(list)
	if not (gx and sx) then
		return
	end
	-- Reuse the last result while the ends stay put.
	local last = view.lastPath
	if last and math.abs(last.x1 - sx) + math.abs(last.z1 - sz) + math.abs(last.x2 - gx) + math.abs(last.z2 - gz) < 24 and frame - last.frame < 15 then
		view.path = last
		return
	end
	local info = PathInsight(sx, sz, gx, gz)
	info.frame = frame
	info.lines = PathLines(info, list)
	view.path, view.lastPath = info, info
end

local function DrawPathCard(below)
	local info = view.path
	if not info then
		return
	end
	local mx, my = Spring.GetMouseState()
	local k = D.UiScale()
	local texts, colors = {}, {}
	for i = 2, #info.lines do
		texts[#texts + 1] = info.lines[i][1]
		colors[#colors + 1] = info.lines[i][2]
	end
	DrawCardAt(mx + 24*k, my - 12*k - (below or 0) - (below and below > 0 and 6*k or 0), "Flight path: " .. info.lines[1][1], nil, texts, k, colors)
end

local function DrawPathWorld()
	local info = view.path
	if not info then
		return
	end
	local function P(f)
		local x, z = info.x1 + (info.x2 - info.x1)*f, info.z1 + (info.z2 - info.z1)*f
		return x, (Spring.GetGroundHeight(x, z) or 0) + 24, z
	end
	local steps = max(2, ceil(info.length/64))
	gl.LineWidth(3)
	gl.Color(1, 1, 1, 0.55)
	gl.BeginEnd(GL.LINE_STRIP, function()
		for i = 0, steps do
			gl.Vertex(P(i/steps))
		end
	end)
	-- Stretches inside anti-air range, coloured by how dangerous each is.
	gl.LineWidth(5)
	for i = 1, #info.spans do
		local span = info.spans[i]
		gl.Color(1, 0.75 - 0.6*span[3], 0.3, 0.9)
		local n = max(1, ceil((span[2] - span[1])*steps))
		gl.BeginEnd(GL.LINE_STRIP, function()
			for j = 0, n do
				gl.Vertex(P(span[1] + (span[2] - span[1])*j/n))
			end
		end)
	end
	gl.LineWidth(1)
	gl.Color(1, 1, 1, 1)
end

function widget:SelectionChanged(selected)
	view.selected = selected or {}
	view.selSet = {}
	for i = 1, #view.selected do
		view.selSet[view.selected[i]] = true
	end
end

function widget:DrawScreen()
	UpdatePathView()
	if Opt('show_hud') then
		DrawCylinder()
	end
	if Opt('show_ledger') then
		DrawLedger()
	end
	if Allies.Visible() then
		Allies.Draw()
	end
	D.DrawGrips()
	local cardH = 0
	if Opt('show_card') then
		cardH = DrawCard()
	end
	DrawPathCard(cardH)
	if menuOpen then
		DrawMenu()
	end
	gl.Color(1, 1, 1, 1)
end

-- Filled threat discs come from the game's ground-volume helper; outlines are the fallback.
if type(gl.Utilities) ~= "table" or not gl.Utilities.DrawGroundCircle then
	pcall(VFS.Include, "LuaRules/Utilities/glVolumes.lua")
end

local function ThreatColour(t)
	-- Redder the faster it kills a Magpie. Stockpilers: by whether they hold a missile.
	local danger = max(0, min(1, 1 - t.ttk/15))
	local stock = StockEstimate(t)
	if stock then
		danger = (stock > 0) and 1 or 0.2
	end
	return 1, 0.75 - 0.6*danger, 0.3, danger
end

function widget:DrawWorldPreUnit()
	if Opt('threat_map') then
		local fill = Opt('threat_style') == 'fill' and type(gl.Utilities) == "table" and gl.Utilities.DrawGroundCircle
		for _, t in pairs(threats) do
			if not t.fighter then
				local r, g, b, danger = ThreatColour(t)
				local seen = t.inLos and 1 or 0.55
				if fill then
					gl.Color(r, g, b, t.building and 0.05 or (0.08 + 0.12*danger)*seen)
					gl.Utilities.DrawGroundCircle(t.x, t.z, t.range)
				end
				gl.LineWidth(t.building and 1 or 2)
				gl.Color(r, g, b, t.building and 0.2 or (0.35 + 0.35*danger)*seen)
				gl.DrawGroundCircle(t.x, t.y, t.z, t.range, 64)
			end
		end
		gl.LineWidth(1)
	end
	if Opt('stale_intel') then
		gl.Color(0.55, 0.55, 0.62, 0.35)
		for i = 1, #routeCache do
			local stale = routeCache[i].stale or {}
			for j = 1, #stale do
				local c = stale[j]
				gl.DrawGroundCircle(c.x, Spring.GetGroundHeight(c.x, c.z) or 0, c.z, LOS_CELL*0.45, 12)
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
			gl.BeginEnd(GL.LINES, function()
				gl.Vertex(r.x1, (Spring.GetGroundHeight(r.x1, r.z1) or 0) + 40, r.z1)
				gl.Vertex(r.x2, r.y + 40, r.z2)
			end)
		end
	end
	DrawPathWorld()
	-- The approach being dragged, or waiting for the next attack: an arrow the way the run will fly, or a ring
	-- where it will come in from. Planned approach routes of launched wings, ending in an arrow at the target.
	gl.LineWidth(3)
	gl.Color(COLOR.ready)
	local ap = approachPoint
	if approachDrag then
		D.Arrow({{approachDrag[1], approachDrag[2]}, {approachDrag[3], approachDrag[4]}})
	elseif ap and ap.x1 then
		D.Arrow({{ap.x1, ap.z1}, {ap.x2, ap.z2}})
	elseif ap and ap.x then
		gl.DrawGroundCircle(ap.x, Spring.GetGroundHeight(ap.x, ap.z) or 0, ap.z, 90, 24)
	end
	gl.LineWidth(2)
	gl.Color(COLOR.ready[1], COLOR.ready[2], COLOR.ready[3], 0.55)
	for _, group in pairs(groups) do
		local unitID = group.routes and next(group.units)
		local route = unitID and group.routes[unitID]
		local tx, _, tz = Spring.GetUnitPosition(group.target)
		if route and #route > 0 and tx then
			local points = {}
			for i = 1, #route do
				points[i] = route[i]
			end
			points[#points + 1] = {tx, tz}
			D.Arrow(points)
		end
	end
	gl.LineWidth(2)
	gl.Color(COLOR.attacking)
	for i = 1, #marks do
		local x, y, z = Spring.GetUnitPosition(marks[i])
		if x then
			gl.DrawGroundCircle(x, y, z, 60, 24)
		end
	end
	gl.LineWidth(1)
	gl.Color(1, 1, 1, 1)
end

-- A line on the ground through points ({x, z} each) with an arrowhead at the last one.
function D.Arrow(points)
	local n = #points
	if n < 2 then
		return
	end
	local function V(x, z)
		gl.Vertex(x, (Spring.GetGroundHeight(x, z) or 0) + 20, z)
	end
	local ax, az, bx, bz = points[n - 1][1], points[n - 1][2], points[n][1], points[n][2]
	local d = Dist2D(ax, az, bx, bz)
	gl.BeginEnd(GL.LINES, function()
		for i = 2, n do
			V(points[i - 1][1], points[i - 1][2])
			V(points[i][1], points[i][2])
		end
		if d > 1 then
			local ux, uz = (bx - ax)/d, (bz - az)/d
			local size = min(160, d*0.4)
			V(bx, bz)
			V(bx - ux*size - uz*size*0.6, bz - uz*size + ux*size*0.6)
			V(bx, bz)
			V(bx - ux*size + uz*size*0.6, bz - uz*size - ux*size*0.6)
		end
	end)
end

function D.Label(x, y, z, str, size, c)
	gl.PushMatrix()
	gl.Translate(x, y, z)
	gl.Billboard()
	Text(str, 0, 0, size, "cvo", c)
	gl.PopMatrix()
end

function widget:DrawWorld()
	-- Wing letters over airborne wings, mark numbers, reload timers, route risk.
	if Opt('route_lines') then
		for i = 1, #routeCache do
			local r = routeCache[i]
			D.Label((r.x1 + r.x2)*0.5, (r.y or 0) + 60, (r.z1 + r.z2)*0.5, string.format("%s risk %d", r.label, floor(r.risk)), 12, COLOR.text)
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
				D.Label(cx, (Spring.GetGroundHeight(cx, cz) or 0) + 220, cz, WING_LETTER[w] .. " " .. #list, 18, COLOR.ready)
			end
		end
	end
	for i = 1, #marks do
		local x, y, z = Spring.GetUnitPosition(marks[i])
		if x then
			D.Label(x, y + 80, z, tostring(i), 20, COLOR.attacking)
		end
	end
	if Opt('threat_map') and Opt('stockpile_watch') then
		for _, t in pairs(threats) do
			local text = ThreatLabel(t)
			if text then
				D.Label(t.x, t.y + 120, t.z, text, 14, t.building and COLOR.muted or COLOR.returning)
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
					D.Label(t.x, t.y + 90, t.z, string.format("reload %.0fs", left), 14, COLOR.ready)
				else
					reloadSeen[unitID] = nil
				end
			end
		end
	end
	gl.Color(1, 1, 1, 1)
end

-- Resize grips: lower right of the cylinder's rim, and the lower right corners of the ledger and the air
-- request panel. Each grip sets its panel's size option.
D.SIZE_KEY = {hud = 'hud_size', ledger = 'ledger_size', requests = 'requests_size'}
D.SIZE_NAME = {hud = 'cylinder', ledger = 'ledger', requests = 'air request panel'}

function D.HudGrip()
	local _, _, cx, cy = ChamberCentre(1)
	local a = -pi/3 -- between chambers C and D
	return cx + cos(a)*hud.radius*0.93, cy + sin(a)*hud.radius*0.93, 9*hud.scale
end

function D.LedgerGrip()
	local x, y, w, h, k = LedgerRect()
	return x + w - 16*k, y - h, x + w, y - h + 16*k
end

local function GripHit(x, y)
	if Allies.Visible() then
		local x1, y1, x2, y2 = Allies.Grip()
		if x >= x1 and x <= x2 and y >= y1 and y <= y2 then
			return 'requests'
		end
	end
	if Opt('show_ledger') then
		local x1, y1, x2, y2 = D.LedgerGrip()
		if x >= x1 and x <= x2 and y >= y1 and y <= y2 then
			return 'ledger'
		end
	end
	if Opt('show_hud') then
		local gx, gy, gr = D.HudGrip()
		if Dist2D(x, y, gx, gy) <= gr*1.3 then
			return 'hud'
		end
	end
	return nil
end

function D.DrawGrips()
	local mx, my = Spring.GetMouseState()
	local over = (dragging and dragging.resize) or GripHit(mx, my)
	if Opt('show_hud') then
		local gx, gy, gr = D.HudGrip()
		local c = over == 'hud' and COLOR.ready or {0.42, 0.41, 0.5, 0.9}
		D.Disc(gx, gy, gr, 20, {0.2, 0.2, 0.25, 0.97}, {0.12, 0.12, 0.15, 0.97})
		D.Arc(gx, gy, gr - 1.5*hud.scale, gr, 1, 20, c)
		gl.Color(c)
		gl.LineWidth(1.5*hud.scale)
		gl.BeginEnd(GL.LINES, function()
			local d = gr*0.45
			gl.Vertex(gx - d, gy + d); gl.Vertex(gx + d, gy - d)
			gl.Vertex(gx + d, gy - d); gl.Vertex(gx + d*0.1, gy - d)
			gl.Vertex(gx + d, gy - d); gl.Vertex(gx + d, gy - d*0.1)
		end)
		gl.LineWidth(1)
	end
	if Opt('show_ledger') then
		local x1, y1, x2, y2 = D.LedgerGrip()
		D.CornerGrip(x1, y1, x2, y2, over == 'ledger')
	end
	if Allies.Visible() then
		local x1, y1, x2, y2 = Allies.Grip()
		D.CornerGrip(x1, y1, x2, y2, over == 'requests')
	end
	gl.Color(1, 1, 1, 1)
end

-- Three short diagonals in a panel's lower right corner.
function D.CornerGrip(x1, y1, x2, y2, hot)
	gl.Color(hot and COLOR.ready or {0.5, 0.49, 0.58, 0.9})
	gl.LineWidth(1.5)
	gl.BeginEnd(GL.LINES, function()
		for i = 1, 3 do
			local d = (x2 - x1)*i/4
			gl.Vertex(x2 - 3 - d, y1 + 3); gl.Vertex(x2 - 3, y1 + 3 + d)
		end
	end)
	gl.LineWidth(1)
end

-- Stored positions follow what is on screen, so a panel pushed against an edge moves back at once.
function D.SettlePositions()
	local vsx, vsy = Spring.GetViewGeometry()
	local _, _, cx, cy = ChamberCentre(1)
	hud.fx, hud.fy = cx/vsx, cy/vsy
	local lx, ly = LedgerRect()
	ledgerPanel.fx, ledgerPanel.fy = lx/vsx, ly/vsy
	local _, mx, top, w, h = MenuLayout()
	menuPanel.fx, menuPanel.fy = (mx + w*0.5)/vsx, (top - h*0.5)/vsy
	local _, ax, atop = Allies.Layout()
	Allies.panel.fx, Allies.panel.fy = ax/vsx, atop/vsy
end

local function LedgerHit(x, y)
	if not Opt('show_ledger') then
		return false
	end
	local lx, ly, lw, lh = LedgerRect()
	return x >= lx and x <= lx + lw and y <= ly and y >= ly - lh
end

local function HudHit(x, y)
	if not Opt('show_hud') then
		return false
	end
	local _, _, cx, cy = ChamberCentre(1)
	return Dist2D(x, y, cx, cy) <= hud.radius
end

function widget:IsAbove(x, y)
	if GripHit(x, y) then
		return true
	end
	if menuOpen then
		local _, mx, top, w, h = MenuLayout()
		if x >= mx and x <= mx + w and y <= top and y >= top - h then
			return true
		end
	end
	if Allies.Hit(x, y) or LedgerHit(x, y) then
		return true
	end
	local over = HudHit(x, y)
	if over then
		local _, _, cx, cy = ChamberCentre(1)
		view.hoverHub = Dist2D(x, y, cx, cy) <= hud.hub
	else
		view.hoverHub = false
	end
	return over
end

local function HudClick(x, y)
	local _, _, cx, cy = ChamberCentre(1)
	if Dist2D(x, y, cx, cy) <= hud.hub then
		ToggleMenu()
		return
	end
	for w = 1, WING_COUNT do
		local chx, chy = ChamberCentre(w)
		if Dist2D(x, y, chx, chy) <= hud.chamber*1.1 then
			local _, ctrl, _, shift = Spring.GetModKeyState()
			local list = SelectWing(w, shift or ctrl)
			local now = frame
			if lastClick.wing == w and now - lastClick.time < 12 then
				local wx, wz = Centroid(list)
				if wx then
					Spring.SetCameraTarget(wx, Spring.GetGroundHeight(wx, wz) or 0, wz)
				end
			end
			lastClick.wing, lastClick.time = w, now
			return
		end
	end
end

function GroundAt(x, y)
	local kind, pos = Spring.TraceScreenRay(x, y, true)
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
	if menuOpen then
		local _, mx, top, w, h, k = MenuLayout()
		if x >= mx and x <= mx + w and y <= top and y >= top - 28*k then
			-- Title bar: drag the menu
			dragging = {what = menuPanel, x0 = x, y0 = y, fx0 = (mx + w*0.5)/Spring.GetViewGeometry(),
				fy0 = (top - h*0.5)/select(2, Spring.GetViewGeometry()), onClick = function() end}
			return true
		end
		if MenuClick(x, y) then
			return true
		end
	end
	D.SettlePositions()
	local grip = GripHit(x, y)
	if grip then
		local _, _, cx, cy = ChamberCentre(1)
		local lx = LedgerRect() -- a corner grip sizes its panel by the drag's distance from the left edge
		if grip == 'requests' then
			lx = select(2, Allies.Layout())
		end
		dragging = {resize = grip, x0 = x, y0 = y, moved = true, onClick = function() end,
			size0 = options[D.SIZE_KEY[grip]].value,
			span0 = grip == 'hud' and max(1, Dist2D(x, y, cx, cy)) or max(1, x - lx), cx = cx, cy = cy, lx = lx}
		return true
	end
	-- Press on a panel: a drag moves it, a click (no drag) acts on release.
	local part, req = Allies.Hit(x, y)
	if part then
		dragging = {what = Allies.panel, x0 = x, y0 = y, fx0 = Allies.panel.fx, fy0 = Allies.panel.fy,
			onClick = function() Allies.Click(part, req) end}
		return true
	end
	if LedgerHit(x, y) then
		local _, ly, _, _, k = LedgerRect()
		dragging = {what = ledgerPanel, x0 = x, y0 = y, fx0 = ledgerPanel.fx, fy0 = ledgerPanel.fy,
			onClick = function()
				if y >= ly - 26*k then
					SetOption('ledger_view', NextOptionValue('ledger_view'))
				end
			end}
		return true
	end
	if not HudHit(x, y) then
		return false
	end
	dragging = {what = hud, x0 = x, y0 = y, fx0 = hud.fx, fy0 = hud.fy, onClick = function() HudClick(x, y) end}
	return true
end

function widget:MouseMove(x, y)
	if dragging and dragging.resize then
		-- Size follows the grip: distance from the cylinder's centre, or the panel's width.
		local key = D.SIZE_KEY[dragging.resize]
		local span = dragging.resize == 'hud' and Dist2D(x, y, dragging.cx, dragging.cy) or (x - dragging.lx)
		local option = options[key]
		local size = floor(dragging.size0*span/dragging.span0/5 + 0.5)*5
		size = max(option.min, min(option.max, size))
		if size ~= option.value then
			option.value = size
		end
		return
	end
	if dragging then
		local dx, dy = x - dragging.x0, y - dragging.y0
		if dragging.moved or dx*dx + dy*dy > 36 then
			dragging.moved = true
			local vsx, vsy = Spring.GetViewGeometry()
			dragging.what.fx = max(0, min(1, dragging.fx0 + dx/vsx))
			dragging.what.fy = max(0, min(1, dragging.fy0 + dy/vsy))
		end
		return
	end
	if approachDrag then
		local gx, gz = GroundAt(x, y)
		if gx then
			approachDrag[3], approachDrag[4] = gx, gz
		end
	end
end

function widget:MouseRelease(x, y, button)
	if dragging then
		widget:MouseMove(x, y)
		local d = dragging
		dragging = nil
		if d.resize then
			local key = D.SIZE_KEY[d.resize]
			SetOption(key, options[key].value) -- saved with the settings
		end
		D.SettlePositions()
		if not d.moved then
			d.onClick()
		end
		return true
	end
	if not approachDrag then
		return false
	end
	widget:MouseMove(x, y)
	local x1, z1, x2, z2 = approachDrag[1], approachDrag[2], approachDrag[3], approachDrag[4]
	local length = Dist2D(x1, z1, x2, z2)
	if length > 80 then
		approachPoint = {dx = (x2 - x1)/length, dz = (z2 - z1)/length, x1 = x1, z1 = z1, x2 = x2, z2 = z2}
		Alert("The next attack flies the way the arrow points, coming in from its tail end.")
	else
		approachPoint = {x = x1, z = z1}
		Alert("The next attack comes in from the marked point.")
	end
	approachMode, approachDrag = false, nil
	return true
end


function widget:GetTooltip(x, y)
	for w = 1, WING_COUNT do
		local chx, chy = ChamberCentre(w)
		if Dist2D(x, y, chx, chy) <= hud.chamber*1.1 then
			local s = WingSummary(w)
			local text = string.format("Wing %s: %d Magpies, %d ready, ammo %d%%, health %d%%.",
				WING_LETTER[w], s.n, s.ready, floor(s.ammo*100), floor(s.health*100))
			local eta, parts = WingETA(w)
			if eta > 0 and parts then
				text = text .. string.format("\nReady in %ds: flight %ds, pad queue %ds, rearm %ds, repair %ds.",
					ceil(eta), ceil(parts.flight), ceil(parts.wait), ceil(parts.rearm), ceil(parts.repair))
			end
			return text .. "\nClick to select, Shift-click to add, double-click to view. Drag to move, drag the grip to resize."
		end
	end
	if menuOpen then
		return "Click a feature to switch it on or off."
	end
	local grip = GripHit(x, y)
	if grip then
		return "Drag to resize the " .. D.SIZE_NAME[grip] .. "."
	end
	if Allies.Hit(x, y) then
		return "Allies asking for air support: !air in chat, or on a map point.\nClick a row to look there, x to dismiss. Drag to move, drag the grip to resize."
	end
	if LedgerHit(x, y) then
		return "Revolver ledger. Click the title bar to switch views. Drag to move, drag the grip to resize."
	end
	return "Revolver. Click the middle for the feature menu. Drag to move, drag the grip to resize."
end

widget.RevolverMenuLayout = MenuLayout
widget.RevolverLedgerRect = LedgerRect
widget.RevolverChamberCentre = ChamberCentre
widget.RevolverGrips = function() local hx, hy, hr = D.HudGrip() local x1, y1, x2, y2 = D.LedgerGrip() return hx, hy, hr, x1, y1, x2, y2 end
widget.RevolverPath = function() UpdatePathView() return view.path end

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
	struck = function() return struck end,
	PathInsight = PathInsight, PathLines = PathLines, PadQueue = PadQueue,
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
	PoolPartial = function(byHand) return PoolPartial(byHand) end, ToggleCalibration = function() return ToggleCalibration() end,
	ToggleMenu = function() return ToggleMenu() end, AssignSelected = function(w) return AssignSelected(w) end,
	menuOpen = function() return menuOpen end, approachMode = function() return approachMode end,
	routes = function() return routeCache end, losMemory = function() return losMemory end,
	StaleCells = StaleCells, CellAge = CellAge, SweepLos = SweepLos, FleetAdvice = FleetAdvice, TargetTable = TargetTable,
	StockEstimate = StockEstimate, ThreatLabel = ThreatLabel, MissilesCovering = MissilesCovering, FinishFrame = FinishFrame,
	WholeWings = WholeWings, SetOption = SetOption, NextOptionValue = NextOptionValue, UpdateRoutes = UpdateRoutes,
	Allies = Allies, C = C,
}
