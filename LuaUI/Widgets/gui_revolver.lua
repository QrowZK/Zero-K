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

local spGetMyTeamID            = Spring.GetMyTeamID
local spGetMyAllyTeamID        = Spring.GetMyAllyTeamID
local spGetTeamUnits           = Spring.GetTeamUnits
local spGetUnitDefID           = Spring.GetUnitDefID
local spGetUnitTeam            = Spring.GetUnitTeam
local spGetUnitAllyTeam        = Spring.GetUnitAllyTeam
local spGetUnitHealth          = Spring.GetUnitHealth
local spGetUnitPosition        = Spring.GetUnitPosition
local spGetUnitRulesParam      = Spring.GetUnitRulesParam
local spGetUnitCurrentCommand  = Spring.GetUnitCurrentCommand
local spGetUnitStates          = Spring.GetUnitStates
local spGetUnitArmored         = Spring.GetUnitArmored
local spGetUnitIsDead          = Spring.GetUnitIsDead
local spValidUnitID            = Spring.ValidUnitID
local spGiveOrderToUnitArray   = Spring.GiveOrderToUnitArray
local spGiveOrderToUnit        = Spring.GiveOrderToUnit
local spGetGameFrame           = Spring.GetGameFrame
local spGetMouseState          = Spring.GetMouseState
local spTraceScreenRay         = Spring.TraceScreenRay
local spIsPosInLos             = Spring.IsPosInLos
local spGetGroundHeight        = Spring.GetGroundHeight
local spSelectUnitArray        = Spring.SelectUnitArray
local spSetCameraTarget        = Spring.SetCameraTarget
local spGetViewGeometry        = Spring.GetViewGeometry
local spPlaySoundFile          = Spring.PlaySoundFile
local spEcho                   = Spring.Echo
local spFindUnitCmdDesc        = Spring.FindUnitCmdDesc
local spGetUnitCmdDescs        = Spring.GetUnitCmdDescs

local floor, ceil, sqrt, min, max, abs = math.floor, math.ceil, math.sqrt, math.min, math.max, math.abs
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
		}
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

options_path = 'Settings/Unit Behaviour/Revolver'
options_order = {
	'wing_size', 'assign_mode', 'ready_ammo', 'ready_health', 'spare_wing',
	'horizon', 'auto_style', 'hold_fire', 'release_near_target', 'time_on_target', 'staging_distance',
	'kill_confirm', 'slow_chain', 'rotate_fire',
	'pad_balance', 'retreat_state',
	'threat_map', 'fighter_alert', 'fighter_pullback', 'reload_tracking', 'sounds',
	'show_hud', 'show_card', 'show_ledger', 'export_csv',
	'fire', 'mark', 'clear_marks', 'recall', 'select_ready',
	'select_1', 'select_2', 'select_3', 'select_4', 'select_5', 'select_6',
	'approach', 'pool', 'calibrate',
}
options = {
	wing_size = {name = 'Wing size', desc = 'Most Magpies in one wing. Extra Magpies go to the next wing.', type = 'number', value = 12, min = 1, max = 40, step = 1},
	assign_mode = {
		name = 'New Magpies join', type = 'radioButton', value = 'fill',
		items = {
			{key = 'fill', name = 'Fill one wing at a time'},
			{key = 'round', name = 'Wings in turn'},
		},
	},
	ready_ammo = {name = 'Ready at ammo (%)', desc = 'A wing is chambered when its average ammo reaches this.', type = 'number', value = 90, min = 10, max = 100, step = 5},
	ready_health = {name = 'Ready at health (%)', desc = 'A wing is chambered when its average health reaches this.', type = 'number', value = 70, min = 10, max = 100, step = 5},
	spare_wing = {name = 'Use wing F as the spare wing', desc = 'Half-empty Magpies are gathered into wing F so full wings stay chambered.', type = 'bool', value = false},
	horizon = {
		name = 'Kill within', desc = 'How fast a target should die. Sets how many Magpies Fire sends.', type = 'radioButton', value = '2',
		items = {
			{key = '1', name = '1 pass'}, {key = '2', name = '2 passes'}, {key = '3', name = '3 passes'},
			{key = '5', name = '5 passes'}, {key = '99', name = 'One sortie'},
		},
	},
	auto_style = {name = 'Pick Strafe or Loopback per target', type = 'bool', value = true},
	hold_fire = {name = 'Hold fire until the target', desc = 'Launched Magpies hold fire so they only shoot their ordered target.', type = 'bool', value = true},
	release_near_target = {name = 'Free fire near the target', desc = 'Within weapon range of the target, Magpies may also shoot units next to it.', type = 'bool', value = false},
	time_on_target = {name = 'Arrive together', desc = 'Wings gather at a staging point before the attack so they arrive at the same time.', type = 'bool', value = true},
	staging_distance = {name = 'Staging distance', type = 'number', value = 1300, min = 700, max = 2500, step = 50},
	kill_confirm = {
		name = 'When a target dies early', type = 'radioButton', value = 'next',
		items = {
			{key = 'next', name = 'Next marked target, else home'},
			{key = 'home', name = 'Go home'},
			{key = 'off', name = 'Do nothing'},
		},
	},
	slow_chain = {name = 'Slow chain', desc = 'When a target reaches 50% slow, extra Magpies move to the next marked target.', type = 'bool', value = true},
	rotate_fire = {name = 'Rotate fire', desc = 'When a wing runs dry, the next chambered wing launches at the same targets.', type = 'bool', value = false},
	pad_balance = {name = 'Balance pads', desc = 'Send returning Magpies to the pad with the shortest wait.', type = 'bool', value = true},
	retreat_state = {
		name = 'Retreat setting for wings', type = 'radioButton', value = 'keep',
		items = {
			{key = 'keep', name = 'Leave as is'},
			{key = '1', name = 'Retreat at 30%'},
			{key = '2', name = 'Retreat at 65%'},
			{key = '3', name = 'Retreat at 99%'},
		},
	},
	threat_map = {name = 'Show anti-air threat map', type = 'bool', value = true},
	fighter_alert = {name = 'Fighter alerts', type = 'bool', value = true},
	fighter_pullback = {name = 'Pull wings back from fighters', type = 'bool', value = false},
	reload_tracking = {name = 'Track long AA reloads', desc = 'Shows when a Hacksaw or other long-reload AA that shot your Magpies is reloading.', type = 'bool', value = true},
	sounds = {name = 'Sounds', type = 'bool', value = true},
	show_hud = {name = 'Show cylinder', type = 'bool', value = true},
	show_card = {name = 'Show breakpoint card on hover', type = 'bool', value = true},
	show_ledger = {name = 'Show ledger', type = 'bool', value = false},
	export_csv = {name = 'Save sorties to file', desc = 'Writes LuaUI/Config/Revolver/*.csv at the end of the game.', type = 'bool', value = true},

	fire = {name = 'Fire', desc = 'Send chambered Magpies at the marked targets, or the enemy under the cursor.', type = 'button', OnChange = function() Fire() end},
	mark = {name = 'Mark target', desc = 'Add the enemy under the cursor to the target list.', type = 'button', OnChange = function() Mark() end},
	clear_marks = {name = 'Clear marks', type = 'button', OnChange = function() ClearMarks() end},
	recall = {name = 'Recall selected', desc = 'Send the selected Magpies, or every airborne wing if none are selected, to pads.', type = 'button', OnChange = function() Recall() end},
	select_ready = {name = 'Select chambered wings', type = 'button', OnChange = function() SelectReady() end},
	select_1 = {name = 'Select wing A', type = 'button', OnChange = function() SelectWing(1) end},
	select_2 = {name = 'Select wing B', type = 'button', OnChange = function() SelectWing(2) end},
	select_3 = {name = 'Select wing C', type = 'button', OnChange = function() SelectWing(3) end},
	select_4 = {name = 'Select wing D', type = 'button', OnChange = function() SelectWing(4) end},
	select_5 = {name = 'Select wing E', type = 'button', OnChange = function() SelectWing(5) end},
	select_6 = {name = 'Select wing F', type = 'button', OnChange = function() SelectWing(6) end},
	approach = {name = 'Approach from cursor', desc = 'The next Fire approaches from the direction of the cursor.', type = 'button', OnChange = function() SetApproach() end},
	pool = {name = 'Pool half-empty Magpies', type = 'button', OnChange = function() PoolPartial() end},
	calibrate = {name = 'Calibration mode (single player)', desc = 'Keeps sending chambered wings at the enemy under the cursor and compares measured hit rates with the Magpie Manual.', type = 'button', OnChange = function() ToggleCalibration() end},
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
local approachPoint
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
	spEcho("Revolver: " .. text)
	if sound and Opt('sounds') then
		spPlaySoundFile(sound, 1, "ui")
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
	AddToWing(unitID, PickWing())
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
	if spGetUnitArmored then
		local armored, multiple = spGetUnitArmored(targetID)
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
	return isNew
end

-- Expected damage to one Magpie flying a straight line through known AA.
local function RouteRisk(x1, z1, x2, z2)
	local length = Dist2D(x1, z1, x2, z2)
	local steps = max(1, ceil(length/50))
	local dt = (length/steps)/magpieStats.speed
	local damage = 0
	for i = 0, steps do
		local f = i/steps
		local x, z = x1 + (x2 - x1)*f, z1 + (z2 - z1)*f
		for _, t in pairs(threats) do
			if not t.fighter and Dist2D(x, z, t.x, t.z) <= t.range then
				damage = damage + t.dps*dt
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
		return {slots = slots, fleet = 0, need = 0, service = 0}
	end
	service = service/n
	local cycle = (magpieStats.bursts - 1)*0.8 + 30 -- firing time plus a typical round trip
	local need = ceil(n*service/(cycle + service))
	return {slots = slots, fleet = n, need = need, service = service, energy = need*(10 + 2.5)}
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
	local index = spFindUnitCmdDesc(unitID, CMD_LOOP_ATTACK)
	local descs = index and spGetUnitCmdDescs(unitID, index, index)
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
	local hist = io.open(EXPORT_DIR .. "history.csv", "a")
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
local function CalibrationTable()
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
	table.sort(list, function(a, b) return a.runs > b.runs end)
	return list
end

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
	if group.approach then
		fromX, fromZ = group.approach[1], group.approach[3]
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
	local plan, spare, shortfall = Allocate(targets, pool, horizon)
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
	spSelectUnitArray(list)
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
	spSelectUnitArray(list)
	return list
end

function SetApproach()
	approachPoint = HoveredGround()
	if approachPoint then
		Alert("Next Fire approaches from the cursor.")
	end
	return approachPoint
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
			local x, y, z = spGetUnitPosition(unitID)
			if x then
				t.x, t.y, t.z, t.inLos, t.lastSeen = x, y, z, true, frame
			end
		else
			t.inLos = false
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
		if run then
			run.damage = run.damage + damage
			lastHit[unitID] = {run = run, frame = frame}
		end
		return
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
			if tx and cx and not t.fighter and DistToSegment(t.x, t.z, cx, cz, tx, tz) <= t.range then
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
	myTeamID = spGetMyTeamID()
	myAllyTeamID = spGetMyAllyTeamID()
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
}

function widget:Initialize()
	if not magpieDefID then
		spEcho("Revolver: no Magpie unit in this game, disabling.")
		widgetHandler:RemoveWidget()
		return
	end
	if CheckSpec() then
		return
	end
	myTeamID = spGetMyTeamID()
	myAllyTeamID = spGetMyAllyTeamID()
	frame = spGetGameFrame()

	local units = spGetTeamUnits(myTeamID) or {}
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
			local allied = spGetTeamUnits(teamID) or {}
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
		local teamID = spGetUnitTeam(visible[i])
		if teamID and not Spring.AreTeamsAllied(teamID, myTeamID) then
			widget:UnitEnteredLos(visible[i], teamID)
		end
	end

	for name, fn in pairs(ACTIONS) do
		widgetHandler.actionHandler:AddAction(widget, name, fn, nil, "t")
	end
	for w = 1, WING_COUNT do
		widgetHandler.actionHandler:AddAction(widget, "revolver_wing_" .. w, function() SelectWing(w) end, nil, "t")
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

local glColor, glRect, glText, glLineWidth = gl.Color, gl.Rect, gl.Text, gl.LineWidth
local glBeginEnd, glVertex, glPushMatrix, glPopMatrix = gl.BeginEnd, gl.Vertex, gl.PushMatrix, gl.PopMatrix
local glTranslate, glBillboard, glDrawGroundCircle = gl.Translate, gl.Billboard, gl.DrawGroundCircle
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
	local vsx = spGetViewGeometry()
	local cx, cy = vsx - hud.x, hud.y
	local angle = pi/2 - (w - 1)*pi/3
	return cx + cos(angle)*(hud.radius - hud.chamber - 4), cy + sin(angle)*(hud.radius - hud.chamber - 4), cx, cy
end

local function Circle(x, y, r, segments, fraction)
	fraction = fraction or 1
	glBeginEnd(GL_LINE_STRIP, function()
		local n = max(2, floor(segments*fraction))
		for i = 0, n do
			local a = pi/2 - 2*pi*fraction*i/n
			glVertex(x + cos(a)*r, y + sin(a)*r)
		end
	end)
end

local function Disc(x, y, r, segments)
	glBeginEnd(GL_TRIANGLE_FAN, function()
		glVertex(x, y)
		for i = 0, segments do
			local a = 2*pi*i/segments
			glVertex(x + cos(a)*r, y + sin(a)*r)
		end
	end)
end

local function DrawCylinder()
	local _, _, cx, cy = ChamberCentre(1)
	glColor(COLOR.panel)
	Disc(cx, cy, hud.radius, 48)
	for w = 1, WING_COUNT do
		local x, y = ChamberCentre(w)
		local s = WingSummary(w)
		glColor(COLOR.ring)
		Disc(x, y, hud.chamber, 24)
		glLineWidth(3)
		glColor(COLOR.ring)
		Circle(x, y, hud.chamber - 3, 32, 1)
		if s.n > 0 then
			glColor(COLOR[s.state] or COLOR.idle)
			Circle(x, y, hud.chamber - 3, 32, s.ammo)
		end
		glLineWidth(1)
		glColor(COLOR.text)
		glText(WING_LETTER[w], x, y + 2, 15, "cv")
		local sub
		if s.n == 0 then
			sub = "-"
		elseif s.state == "pad" or s.state == "returning" then
			sub = s.n .. " " .. ceil(WingETA(w)) .. "s"
		else
			sub = s.n .. " " .. floor(s.ammo*100 + 0.5) .. "%"
		end
		glColor(COLOR.muted)
		glText(sub, x, y - 12, 10, "cv")
	end
	local plan = PadPlan()
	glColor(COLOR.muted)
	glText("Pads " .. plan.slots .. " / need " .. plan.need .. "   Fleet " .. plan.fleet, cx, cy - hud.radius - 14, 11, "cv")
	for i = 1, #alerts do
		local a = alerts[#alerts - i + 1]
		if frame - a.frame < 30*8 then
			glText(a.text, cx, cy + hud.radius + 6 + 14*(i - 1), 11, "cv")
		end
	end
	glColor(1, 1, 1, 1)
end

local function CardLines(target)
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

	local pool = ReadyPool()
	local tx, _, tz = spGetUnitPosition(target)
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
	glColor(COLOR.panel)
	glRect(x, y - h, x + w, y)
	for i = 1, #lines do
		glColor(i == 1 and COLOR.text or COLOR.muted)
		glText(lines[i], x + 8, y - 16*i, 12, "o")
	end
	glColor(1, 1, 1, 1)
end

local function DrawLedger()
	local vsx, vsy = spGetViewGeometry()
	local x, y, w, h = ledgerPanel.x, vsy - ledgerPanel.y, ledgerPanel.w, ledgerPanel.h
	glColor(COLOR.panel)
	glRect(x, y - h, x + w, y)
	local t = GameTotals()
	glColor(COLOR.text)
	glText("Revolver ledger", x + 8, y - 16, 13, "o")
	glColor(COLOR.muted)
	glText(string.format("Runs %d  Bursts %d  Hit %s  Kills %d  Lost %d", t.runs, t.bursts,
		t.hit and string.format("%.2f", t.hit) or "-", t.kills, t.lost), x + 8, y - 32, 11, "o")
	glText(string.format("Metal killed %d  lost %d  Pad energy %d", totals.metalKilled, totals.metalLost,
		floor(totals.rearmEnergy + totals.repairEnergy)), x + 8, y - 46, 11, "o")
	if #history > 0 then
		local sum, n = 0, 0
		for i = max(1, #history - 9), #history do
			sum, n = sum + history[i].hit, n + 1
		end
		glText(string.format("Last %d games: hit %.2f", n, sum/n), x + 8, y - 60, 11, "o")
	end

	-- Hit factor per run, last 20, against the simulated factor.
	local gx, gy, gw, gh = x + 30, y - h + 20, w - 40, h - 100
	glColor(COLOR.ring)
	glRect(gx, gy, gx + gw, gy + 1)
	glRect(gx, gy + gh, gx + gw, gy + gh + 1)
	glColor(COLOR.muted)
	glText("1.0", gx - 4, gy + gh, 9, "rv")
	glText("0", gx - 4, gy, 9, "rv")
	local first = max(1, #runs - 19)
	local slot = gw/20
	for i = first, #runs do
		local run = runs[i]
		local hit = RunHitFactor(run)
		local px = gx + (i - first)*slot + slot*0.5
		if hit then
			glColor(run.mode == "loopback" and COLOR.attacking or COLOR.ready)
			glRect(px - slot*0.3, gy, px + slot*0.3, gy + min(1, hit)*gh)
		end
		local expected = ExpectedHitFactor(run)
		if expected then
			glColor(COLOR.text)
			glRect(px - slot*0.45, gy + expected*gh, px + slot*0.45, gy + expected*gh + 2)
		end
	end
	if calibration then
		local list = CalibrationTable()
		glColor(COLOR.text)
		for i = 1, min(3, #list) do
			local a = list[i]
			glText(string.format("%s %s: measured %.2f vs %.2f (%d runs)", a.target, a.mode, a.measured, a.expected, a.runs),
				x + 8, y - 74 - 13*(i - 1), 10, "o")
		end
	end
	glColor(1, 1, 1, 1)
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
end

function widget:DrawWorldPreUnit()
	if Opt('threat_map') then
		glLineWidth(1.5)
		for unitID, t in pairs(threats) do
			if not t.fighter then
				-- Redder the faster it kills a Magpie.
				local danger = max(0, min(1, 1 - t.ttk/15))
				glColor(1, 0.75 - 0.6*danger, 0.3, t.inLos and 0.55 or 0.25)
				glDrawGroundCircle(t.x, t.y, t.z, t.range, 48)
			end
		end
	end
	glColor(COLOR.attacking)
	for i = 1, #marks do
		local x, y, z = spGetUnitPosition(marks[i])
		if x then
			glDrawGroundCircle(x, y, z, 60, 20)
		end
	end
	glLineWidth(1)
	glColor(1, 1, 1, 1)
end

function widget:DrawWorld()
	-- Wing letters over airborne wings, mark numbers, reload timers.
	for w = 1, WING_COUNT do
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
				glPushMatrix()
				glTranslate(cx, cy, cz)
				glBillboard()
				glColor(COLOR.ready)
				glText(WING_LETTER[w] .. " " .. #list, 0, 0, 18, "cv")
				glPopMatrix()
			end
		end
	end
	for i = 1, #marks do
		local x, y, z = spGetUnitPosition(marks[i])
		if x then
			glPushMatrix()
			glTranslate(x, y + 80, z)
			glBillboard()
			glColor(COLOR.attacking)
			glText(tostring(i), 0, 0, 20, "cv")
			glPopMatrix()
		end
	end
	if Opt('reload_tracking') then
		for unitID, fired in pairs(reloadSeen) do
			local t = threats[unitID]
			local def = t and aaDefs[t.defID]
			if def and def.reload then
				local left = def.reload - (frame - fired)/30
				if left > 0 then
					glPushMatrix()
					glTranslate(t.x, t.y + 90, t.z)
					glBillboard()
					glColor(COLOR.ready)
					glText(string.format("reload %.0fs", left), 0, 0, 14, "cv")
					glPopMatrix()
				else
					reloadSeen[unitID] = nil
				end
			end
		end
	end
	glColor(1, 1, 1, 1)
end

function widget:IsAbove(x, y)
	if not Opt('show_hud') then
		return false
	end
	local _, _, cx, cy = ChamberCentre(1)
	return Dist2D(x, y, cx, cy) <= hud.radius
end

function widget:MousePress(x, y, button)
	if button ~= 1 or not widget:IsAbove(x, y) then
		return false
	end
	for w = 1, WING_COUNT do
		local chx, chy = ChamberCentre(w)
		if Dist2D(x, y, chx, chy) <= hud.chamber then
			local list = SelectWing(w)
			local now = frame
			if lastClick.wing == w and now - lastClick.time < 12 then
				local wx, wz = Centroid(list)
				if wx then
					spSetCameraTarget(wx, spGetGroundHeight(wx, wz) or 0, wz)
				end
			end
			lastClick.wing, lastClick.time = w, now
			return true
		end
	end
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
	return "Revolver"
end

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
}
