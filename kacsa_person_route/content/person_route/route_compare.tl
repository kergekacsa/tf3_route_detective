-- The options of a trip: on foot, by car, and by lines. The option the game chose shows the route of the game as far as
-- the game exposes it: the path the person walks or drives now, and the line of the current leg. The parts the game does
-- not expose (the legs before and after the current one) and the options the game did not choose are the mod's own
-- estimate, from the pathfinder of the game and the line network.

local route_state = ug_require "kacsa_person_route::/person_route/route_state.tl" as PrcRouteStateModule
local route_lines = ug_require "kacsa_person_route::/person_route/route_lines.tl" as PrcRouteLinesModule

local route_compare : PrcRouteCompareModule = {}

-- Routes by lines that are assembled and timed, of which the card lists the shortest ones.
local MAX_LINE_CANDIDATES <const> = 5
-- The second route by lines is listed when its time is at most this multiple of the time of the shortest.
local SECOND_ROUTE_MAX_RATIO <const> = 1.10
local MIN_SPEED_MPS <const> = 1.0
local MS_PER_SECOND <const> = 1000
local SECONDS_PER_MINUTE <const> = 60
-- The card shows the time of a walk or a drive with the formatter of the game, which gave seconds for 96 s and minutes
-- for 4 min. Below this many seconds, two such times count as the same only when their whole seconds are the same.
local SHOWN_IN_SECONDS_BELOW <const> = 120
-- The part of a minute from which the minutes of an option are rounded up.
local ROUND_UP_FROM <const> = 0.5
local LOG_PREFIX <const> = "[PersonRoute] "

local function component(entity : Engine.Entity, kind : Engine.ComponentType) : any
	if entity == nil or entity < 0 then
		return nil
	end
	return api.engine.getComponent(entity, kind)
end

route_compare.pathLengthAndTime = function(edges : {{EdgeId, boolean}}) : number, number
	local meters = 0.0
	local seconds = 0.0
	for __, pair in ipairs(edges) do
		local edgeId = pair[1]
		local network = component(edgeId.entity, api.type.ComponentType.TRANSPORT_NETWORK) as Engine.Component.TransportNetwork
		local edge = network and network.edges and network.edges[edgeId.index + 1]
		if edge then
			local length = edge.geometry and edge.geometry.length or 0
			meters = meters + length
			local speed = edge.speedLimit or 0
			if edge.curveSpeedLimit and edge.curveSpeedLimit > 0 and edge.curveSpeedLimit < speed then
				speed = edge.curveSpeedLimit
			end
			seconds = seconds + length / math.max(speed, MIN_SPEED_MPS)
		end
	end
	return meters, seconds
end

-- Completes a leg: its edges, its length, and its time when the leg is a walk or a drive over
-- known edges. A walk between two stations without a path keeps the time from the distance between the stations.
local function finish(leg : PrcRouteLeg, walkSpeed : number) : PrcRouteLeg
	leg.edges = route_lines.legPath(leg)
	if leg.edges ~= nil then
		local meters, driveSeconds = route_compare.pathLengthAndTime(leg.edges)
		leg.meters = meters
		if leg.car then
			leg.seconds = driveSeconds
		elseif leg.line == nil then
			leg.seconds = meters / walkSpeed
		end
	elseif leg.line == nil and leg.seconds ~= nil then
		leg.meters = leg.seconds * walkSpeed
	end
	return leg
end

local record MinutesPart
	leg : PrcRouteLeg
	wait : boolean
	order : integer
	-- the part of a minute that rounding down left out
	rest : number
end

-- Sets the whole minutes of an option, and of the time and the wait of each of its legs. The parts add up to the minutes
-- of the option: each part is rounded down, and the parts with the largest rest take the minutes that are still missing.
local function setMinutes(result : PrcOption)
	local parts : {MinutesPart} = {}
	local given = 0
	local function add(leg : PrcRouteLeg, value : number, wait : boolean)
		if value == nil then
			return
		end
		local minutes = math.floor(value / SECONDS_PER_MINUTE)
		if wait then
			leg.waitMinutes = minutes
		else
			leg.minutes = minutes
		end
		given = given + minutes
		parts[#parts + 1] = { leg = leg, wait = wait, order = #parts + 1, rest = value / SECONDS_PER_MINUTE - minutes }
	end
	for __, leg in ipairs(result.legs) do
		add(leg, leg.seconds, false)
		add(leg, leg.waitSeconds, true)
	end
	result.minutes = math.floor(result.seconds / SECONDS_PER_MINUTE + ROUND_UP_FROM)
	table.sort(parts, function(a : MinutesPart, b : MinutesPart) : boolean
		if a.rest ~= b.rest then
			return a.rest > b.rest
		end
		return a.order < b.order
	end)
	for i = 1, math.min(result.minutes - given, #parts) do
		local part = parts[i]
		if part.wait then
			part.leg.waitMinutes = part.leg.waitMinutes + 1
		else
			part.leg.minutes = part.leg.minutes + 1
		end
	end
end

-- An option owns copies of its legs: two routes of the line search can share a leg, and the minutes of a leg depend on
-- the option.
local function option(kind : string, chosen : boolean, legs : {PrcRouteLeg}, note? : string) : PrcOption
	local result : PrcOption = { kind = kind, chosen = chosen, legs = {}, note = note }
	for i, leg in ipairs(legs or {}) do
		local copy : {string : any} = {}
		for field, value in pairs(leg as {string : any}) do
			copy[field] = value
		end
		result.legs[i] = copy as PrcRouteLeg
	end
	result.available = #result.legs > 0
	if result.available then
		result.seconds = 0
		result.meters = 0
		for __, leg in ipairs(result.legs) do
			result.seconds = result.seconds + (leg.seconds or 0) + (leg.waitSeconds or 0)
			result.meters = result.meters + (leg.meters or 0)
		end
		setMinutes(result)
	end
	return result
end

-- The option on foot or by car. When the game chose it and the person is on the way, its one leg is the path of the game.
local function directOption(kind : string, chosen : boolean, state : PrcRouteState, current : {{EdgeId, boolean}}, walkSpeed : number) : PrcOption
	local mode = kind == "car" and api.type["enum"].TransportMode.CAR or api.type["enum"].TransportMode.PERSON
	local leg : PrcRouteLeg = { fromBuilding = state.originEntity, toBuilding = state.targetEntity, car = kind == "car" }
	local note : string
	if chosen and #current > 0 then
		leg.edges = current
		leg.current = true
	else
		leg.edges, note = route_lines.findPath(route_lines.buildingNodes(state.originEntity, mode), route_lines.buildingNodes(state.targetEntity, mode), { mode })
	end
	if leg.edges == nil then
		return option(kind, chosen, nil, note)
	end
	return option(kind, chosen, { finish(leg, walkSpeed) })
end

-- One walk for walks that follow each other: from the start of the first to the end of the last, on the path of the
-- pathfinder between these two places. When the pathfinder finds no such path, the walk is the sum of its parts. A part
-- between a building and a station counts only when the pathfinder finds it. nil when no part counts.
local function joinedWalk(walks : {PrcRouteLeg}, walkSpeed : number) : PrcRouteLeg
	if #walks == 1 then
		local only = finish(walks[1], walkSpeed)
		if only.edges == nil and (only.fromBuilding ~= nil or only.toBuilding ~= nil) then
			return nil
		end
		return only
	end
	local first, last = walks[1], walks[#walks]
	local direct : PrcRouteLeg = { fromBuilding = first.fromBuilding, fromStation = first.fromStation, toBuilding = last.toBuilding, toStation = last.toStation }
	if finish(direct, walkSpeed).edges ~= nil then
		return direct
	end

	local sum : PrcRouteLeg = { seconds = 0, meters = 0 }
	local edges : {{EdgeId, boolean}} = {}
	local counted = false
	for __, walk in ipairs(walks) do
		local part = joinedWalk({ walk }, walkSpeed)
		if part ~= nil then
			if not counted then
				sum.fromBuilding, sum.fromStation = part.fromBuilding, part.fromStation
				counted = true
			end
			sum.toBuilding, sum.toStation = part.toBuilding, part.toStation
			sum.seconds = sum.seconds + (part.seconds or 0)
			sum.meters = sum.meters + (part.meters or 0)
			for __, pair in ipairs(part.edges or {}) do
				edges[#edges + 1] = pair
			end
		end
	end
	if not counted then
		return nil
	end
	if #edges > 0 then
		sum.edges = edges
	end
	return sum
end

-- The legs of a route by lines between two ends. An end is a building, with the walk between it and the nearest station
-- of the route, or nothing. `startStation` and `endStation` are the ends of the route when it has no legs.
local function assemble(routeLegs : {PrcRouteLeg}, originEntity : Engine.Entity, startStation : Engine.Entity, endStation : Engine.Entity,
	targetEntity : Engine.Entity, walkSpeed : number) : {PrcRouteLeg}
	local parts : {PrcRouteLeg} = {}
	local first = routeLegs[1] and routeLegs[1].fromStation or startStation
	if originEntity ~= nil and first ~= nil then
		parts[#parts + 1] = { fromBuilding = originEntity, toStation = first }
	end
	for __, leg in ipairs(routeLegs) do
		parts[#parts + 1] = leg
	end
	local last = #routeLegs > 0 and routeLegs[#routeLegs].toStation or endStation
	if targetEntity ~= nil and last ~= nil then
		parts[#parts + 1] = { fromStation = last, toBuilding = targetEntity }
	end

	-- Walks that follow each other become one leg.
	local legs : {PrcRouteLeg} = {}
	local walks : {PrcRouteLeg} = {}
	local function closeWalks()
		local joined = #walks > 0 and joinedWalk(walks, walkSpeed) or nil
		if joined ~= nil then
			legs[#legs + 1] = joined
		end
		walks = {}
	end
	for __, leg in ipairs(parts) do
		if leg.line == nil then
			walks[#walks + 1] = leg
		else
			closeWalks()
			legs[#legs + 1] = finish(leg, walkSpeed)
		end
	end
	closeWalks()
	return legs
end

-- The route of a person who uses lines: the legs the game exposes (the walk the person is on, the line of the current
-- leg) and the mod's estimate of the legs before and after them. nil when the game exposes no leg.
local function actualLines(state : PrcRouteState, current : {{EdgeId, boolean}}, originStations : {Engine.Entity}, search : PrcLineSearch,
	walkSpeed : number) : {PrcRouteLeg}
	local walking = state.phase == "walking" and #current > 0
	local legs : {PrcRouteLeg} = {}
	-- The walk the person is on replaces the estimate of that walk at the end of the legs so far.
	local function knownWalk(toStation : Engine.Entity)
		while #legs > 0 and legs[#legs].line == nil do
			legs[#legs] = nil
		end
		local leg : PrcRouteLeg = { edges = current, current = true, toStation = toStation }
		if toStation == nil then
			leg.toBuilding = state.targetEntity
		end
		legs[#legs + 1] = finish(leg, walkSpeed)
	end

	if state.line ~= nil and state.boardStation ~= nil then
		local toBoard = route_lines.search({ state.boardStation }, walkSpeed)
		local before : PrcLineEstimate
		for __, station in ipairs(originStations) do
			local candidate = toBoard.routeFrom(station)
			if candidate ~= nil and (before == nil or candidate.totalSeconds < before.totalSeconds) then
				before = candidate
			end
		end
		legs = assemble(before and before.legs or {}, state.originEntity, state.boardStation, nil, nil, walkSpeed)
		if walking then
			knownWalk(state.boardStation)
		end
		legs[#legs + 1] = finish({
			line = state.line,
			fromStation = state.boardStation,
			toStation = state.leaveStation,
			fromStopIndex = state.boardStopIndex,
			toStopIndex = state.leaveStopIndex,
			seconds = route_lines.rideSeconds(state.line, state.boardStopIndex, state.leaveStopIndex),
			waitSeconds = route_lines.waitSeconds(state.line),
			current = not walking,
		}, walkSpeed)
		local after = search.routeFrom(state.leaveStation)
		for __, leg in ipairs(assemble(after and after.legs or {}, nil, nil, state.leaveStation, state.targetEntity, walkSpeed)) do
			legs[#legs + 1] = leg
		end
		return legs
	end
	if walking then
		-- A walk with no line ahead is the walk after the last ride.
		local best = search.options(originStations, 1)[1]
		legs = assemble(best and best.legs or {}, state.originEntity, nil, nil, nil, walkSpeed)
		knownWalk(nil)
		return legs
	end
	return nil
end

local function rideLines(legs : {PrcRouteLeg}) : string
	local parts : {string} = {}
	for __, leg in ipairs(legs) do
		if leg.line ~= nil then
			parts[#parts + 1] = tostring(leg.line)
		end
	end
	return table.concat(parts, ",")
end

local KIND_ORDER : {string : integer} = { walk = 1, car = 2, lines = 3 }

-- The time of an option as the card shows it, in seconds: whole minutes, or whole seconds for a walk or a drive that is
-- shorter than SHOWN_IN_SECONDS_BELOW.
local function shownSeconds(candidate : PrcOption) : integer
	if candidate.kind ~= "lines" and candidate.seconds < SHOWN_IN_SECONDS_BELOW then
		return math.floor(candidate.seconds)
	end
	return candidate.minutes * SECONDS_PER_MINUTE
end

-- The shortest option first, by the time the card shows. Of options with the same shown time, the choice of the game
-- comes first, then the shorter one, then walk, car, lines. An option that is not available comes last.
local function bySeconds(a : PrcOption, b : PrcOption) : boolean
	if a.available ~= b.available then
		return a.available
	end
	if a.available then
		local shownA, shownB = shownSeconds(a), shownSeconds(b)
		if shownA ~= shownB then
			return shownA < shownB
		end
		if a.chosen ~= b.chosen then
			return a.chosen == true
		end
		if a.seconds ~= b.seconds then
			return a.seconds < b.seconds
		end
	end
	return KIND_ORDER[a.kind] < KIND_ORDER[b.kind]
end

-- Of options sorted by time: the shortest, the second when its time is close to the shortest, and the choice of the game.
local function shortlist(options : {PrcOption}) : {PrcOption}
	local kept : {PrcOption} = {}
	for i, candidate in ipairs(options) do
		if i == 1 or candidate.chosen or (i == 2 and candidate.seconds <= options[1].seconds * SECOND_ROUTE_MAX_RATIO) then
			kept[#kept + 1] = candidate
		end
	end
	return kept
end

-- The options by lines, shortest first. The route of the person takes the place of the estimate with the same lines.
local function linesOptions(state : PrcRouteState, chosen : boolean, current : {{EdgeId, boolean}}, walkSpeed : number) : {PrcOption}
	local originStations = route_lines.stationsInReach({ state.originEntity })
	local targetStations = route_lines.stationsInReach({ state.targetEntity })
	local search = route_lines.search(targetStations, walkSpeed)
	local options : {PrcOption} = {}
	for __, route in ipairs(search.options(originStations, MAX_LINE_CANDIDATES)) do
		options[#options + 1] = option("lines", false, assemble(route.legs, state.originEntity, nil, nil, state.targetEntity, walkSpeed))
	end
	table.sort(options, bySeconds)
	if chosen then
		local actual = actualLines(state, current, originStations, search, walkSpeed)
		if actual ~= nil and #actual > 0 then
			local lines = rideLines(actual)
			for i = #options, 1, -1 do
				if rideLines(options[i].legs) == lines then
					table.remove(options, i)
				end
			end
			options[#options + 1] = option("lines", true, actual)
			table.sort(options, bySeconds)
		elseif #options > 0 then
			options[1].chosen = true
		end
	end
	options = shortlist(options)
	if #options == 0 then
		local note = (#originStations == 0 or #targetStations == 0) and "prc_note_no_station" or "prc_note_no_shared_line"
		options[1] = option("lines", chosen, nil, note)
	end
	return options
end

route_compare.compare = function(personEntity : Engine.Entity, state : PrcRouteState) : PrcCompareResult
	local started = os.clock()
	local result : PrcCompareResult = { options = {} }
	local simPerson = component(personEntity, api.type.ComponentType.SIM_PERSON) as Engine.Component.SimPerson
	if not simPerson or state == nil then
		result.error = "prc_note_no_person"
		return result
	end
	result.originEntity = state.originEntity
	result.targetEntity = state.targetEntity
	result.chosen = simPerson.lastMoveMode
	if state.originEntity == nil or state.originEntity < 0 or state.targetEntity == nil or state.targetEntity < 0
		or state.originEntity == state.targetEntity then
		result.error = "prc_note_no_trip"
		return result
	end

	local moveModes = api.type["enum"].MoveMode
	local walkSpeed = math.max(simPerson.walkSpeed or 0, MIN_SPEED_MPS)
	local current = route_state.currentPath(personEntity)
	local platformWalks, entranceWalks, nearestWalks = route_lines.batch(function()
		result.options[1] = directOption("walk", result.chosen == moveModes.WALK, state, current, walkSpeed)
		result.options[2] = directOption("car", result.chosen == moveModes.DRIVE, state, current, walkSpeed)
		for __, lines in ipairs(linesOptions(state, result.chosen == moveModes.LINES, current, walkSpeed)) do
			result.options[#result.options + 1] = lines
		end
	end)
	table.sort(result.options, bySeconds)
	print(LOG_PREFIX .. "options of person " .. tostring(personEntity) .. ": " .. tostring(#result.options) .. " in "
		.. string.format("%.0f", (os.clock() - started) * MS_PER_SECOND) .. " ms, station walks: " .. tostring(platformWalks)
		.. " by platform, " .. tostring(entranceWalks) .. " by entrance, " .. tostring(nearestWalks) .. " by nearest street")
	return result
end

return route_compare
