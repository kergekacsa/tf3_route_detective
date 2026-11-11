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
local LINE_COLOR_ALPHA <const> = 0.95
local MS_PER_SECOND <const> = 1000
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

local function lineColor(line : Engine.Entity) : {number}
	local color : {number}
	pcall(function()
		local c = (component(line, api.type.ComponentType.COLOR) as Engine.Component.Color).color
		color = { c.x, c.y, c.z, LINE_COLOR_ALPHA }
	end)
	return color
end

-- Completes a leg: its edges, its length, the colour of its line, and its time when the leg is a walk or a drive over
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
	if leg.line ~= nil then
		leg.color = lineColor(leg.line)
	end
	return leg
end

local function option(kind : string, chosen : boolean, legs : {PrcRouteLeg}, note? : string) : PrcOption
	local result : PrcOption = { kind = kind, chosen = chosen, legs = legs or {}, note = note }
	result.available = #result.legs > 0
	if result.available then
		result.seconds = 0
		result.meters = 0
		for __, leg in ipairs(result.legs) do
			result.seconds = result.seconds + (leg.seconds or 0) + (leg.waitSeconds or 0)
			result.meters = result.meters + (leg.meters or 0)
		end
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

-- The legs of a route by lines between two ends. An end is a building, with the walk between it and the nearest station
-- of the route, or nothing. `startStation` and `endStation` are the ends of the route when it has no legs.
local function assemble(routeLegs : {PrcRouteLeg}, originEntity : Engine.Entity, startStation : Engine.Entity, endStation : Engine.Entity,
	targetEntity : Engine.Entity, walkSpeed : number) : {PrcRouteLeg}
	local legs : {PrcRouteLeg} = {}
	-- A walk between a building and a station counts only when the pathfinder finds it.
	local function walk(leg : PrcRouteLeg)
		if finish(leg, walkSpeed).edges ~= nil then
			legs[#legs + 1] = leg
		end
	end
	local first = routeLegs[1] and routeLegs[1].fromStation or startStation
	if originEntity ~= nil and first ~= nil then
		walk({ fromBuilding = originEntity, toStation = first })
	end
	for __, leg in ipairs(routeLegs) do
		legs[#legs + 1] = finish(leg, walkSpeed)
	end
	local last = #routeLegs > 0 and routeLegs[#routeLegs].toStation or endStation
	if targetEntity ~= nil and last ~= nil then
		walk({ fromStation = last, toBuilding = targetEntity })
	end
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

-- The shortest option first. An option that is not available comes last, and equal times keep walk, car, lines.
local function bySeconds(a : PrcOption, b : PrcOption) : boolean
	if a.available ~= b.available then
		return a.available
	end
	if a.available and a.seconds ~= b.seconds then
		return a.seconds < b.seconds
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
	route_lines.batch(function()
		result.options[1] = directOption("walk", result.chosen == moveModes.WALK, state, current, walkSpeed)
		result.options[2] = directOption("car", result.chosen == moveModes.DRIVE, state, current, walkSpeed)
		for __, lines in ipairs(linesOptions(state, result.chosen == moveModes.LINES, current, walkSpeed)) do
			result.options[#result.options + 1] = lines
		end
	end)
	table.sort(result.options, bySeconds)
	print(LOG_PREFIX .. "options of person " .. tostring(personEntity) .. ": " .. tostring(#result.options) .. " in "
		.. string.format("%.0f", (os.clock() - started) * MS_PER_SECOND) .. " ms")
	return result
end

return route_compare
