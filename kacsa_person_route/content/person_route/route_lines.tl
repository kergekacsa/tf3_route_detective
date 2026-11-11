-- The mod's own search for routes by lines: a shortest-route search over the stations of the map. A ride on a line from
-- one stop to a later stop costs the wait for the line plus the section times of a vehicle. A walk between two stations
-- in reach of each other costs the distance at the walk speed. A route may use any number of lines. The game does not
-- expose its own routes, so the result is an estimate.

local route_state = ug_require "kacsa_person_route::/person_route/route_state.tl" as PrcRouteStateModule

local route_lines : PrcRouteLinesModule = {}

-- A person waits on average half an interval for the next vehicle of a line.
local WAIT_FRACTION_OF_INTERVAL <const> = 0.5
-- A line whose frequency is below this has no vehicle (line_util.calculateFrequencySeconds of the game uses the same bound).
local MIN_FREQUENCY <const> = 0.0001
local MIN_SPEED_MPS <const> = 1.0

local record LineInfo
	--- the station of each stop; position 1 is stop 0
	stations : {Engine.Entity}
	--- the seconds of each section; position 1 is the section after stop 0. nil when the line has no vehicle
	times : {number}
	--- nil when the line has no frequency
	wait : number
end

local record NetEdge
	from : Engine.Entity
	to : Engine.Entity
	cost : number
	leg : PrcRouteLeg
end

local record Network
	outOf : {Engine.Entity : {NetEdge}}
	into : {Engine.Entity : {NetEdge}}
	station2stations : {Engine.Entity : {Engine.Entity : number}}
	--- m/s on foot
	speed : number
end

-- Engine data that one computation asks for many times. It lives for the time of one `route_lines.batch` call.
local record Batch
	station2edges : {Engine.Entity : {{any}}}
	catchable2stations : {Engine.Entity : {Engine.Entity}}
	stationNodes : {Engine.Entity : {NodeId}}
	platformNodes : {Engine.Entity : {NodeId}}
	entranceNodes : {Engine.Entity : {NodeId}}
	network : Network
	-- walks with a station at one end whose path starts or ends at a platform, at a street edge of an entrance, and at
	-- the street edge nearest to the station
	platformWalks : integer
	entranceWalks : integer
	nearestWalks : integer
end
local batch : Batch

route_lines.batch = function(fn : function()) : integer, integer, integer
	batch = { stationNodes = {}, platformNodes = {}, entranceNodes = {}, platformWalks = 0, entranceWalks = 0, nearestWalks = 0 }
	local ok, message = pcall(fn as function() : any)
	local platformWalks, entranceWalks, nearestWalks = batch.platformWalks, batch.entranceWalks, batch.nearestWalks
	batch = nil
	if not ok then
		error(message, 0)
	end
	return platformWalks, entranceWalks, nearestWalks
end

-- For each station the edges in its catchment area, each with its distance from the station.
local function station2edges() : {Engine.Entity : {{any}}}
	if batch == nil then
		return api.engine.system.catchmentAreaSystem.getStation2edgesMap() as {Engine.Entity : {{any}}}
	end
	if batch.station2edges == nil then
		batch.station2edges = api.engine.system.catchmentAreaSystem.getStation2edgesMap() as {Engine.Entity : {{any}}}
	end
	return batch.station2edges
end

route_lines.stationsInReach = function(entities : {Engine.Entity}) : {Engine.Entity}
	local catchable2stations = batch and batch.catchable2stations
	if catchable2stations == nil then
		catchable2stations = {}
		for station, __ in pairs(station2edges()) do
			for __, catchable in ipairs(api.engine.system.catchmentAreaSystem.getStationCatchables(station, false) or {}) do
				catchable2stations[catchable] = catchable2stations[catchable] or {}
				local list = catchable2stations[catchable]
				list[#list + 1] = station
			end
		end
		if batch ~= nil then
			batch.catchable2stations = catchable2stations
		end
	end
	local seen : {Engine.Entity : boolean} = {}
	local stations : {Engine.Entity} = {}
	for __, entity in ipairs(entities) do
		for __, station in ipairs(catchable2stations[entity] or {}) do
			if not seen[station] then
				seen[station] = true
				stations[#stations + 1] = station
			end
		end
	end
	table.sort(stations)
	return stations
end

local function component(entity : Engine.Entity, kind : Engine.ComponentType) : any
	if entity == nil or entity < 0 then
		return nil
	end
	return api.engine.getComponent(entity, kind)
end

local function sectionTimes(line : Engine.Entity) : {number}
	local vehicles = api.engine.system.transportVehicleSystem.getLineVehicles(line)
	if vehicles == nil or #vehicles == 0 then
		return nil
	end
	local vehicle = component(vehicles[1], api.type.ComponentType.TRANSPORT_VEHICLE) as Engine.Component.TransportVehicle
	local times = vehicle and vehicle.sectionTimes
	if times == nil or #times == 0 then
		return nil
	end
	local copy : {number} = {}
	for i = 1, #times do
		copy[i] = times[i]
	end
	return copy
end

route_lines.waitSeconds = function(line : Engine.Entity) : number
	local frequency = api.engine.util.line.getMaxFrequency(line)
	if frequency == nil or frequency < MIN_FREQUENCY then
		return nil
	end
	return WAIT_FRACTION_OF_INTERVAL / frequency
end

route_lines.rideSeconds = function(line : Engine.Entity, fromStop : integer, toStop : integer) : number
	local times = sectionTimes(line)
	if times == nil then
		return nil
	end
	local seconds = 0.0
	local stop = fromStop
	while stop ~= toStop do
		seconds = seconds + (times[stop + 1] or 0)
		stop = (stop + 1) % #times
	end
	return seconds
end

route_lines.findPath = function(fromNodes : {NodeId}, toNodes : {NodeId}, modes : {TransportMode}) : {{EdgeId, boolean}}, string
	if fromNodes == nil or toNodes == nil or #fromNodes == 0 or #toNodes == 0 then
		return nil, "prc_note_no_nodes"
	end
	local ok, result = pcall(api.engine.util.pathfinding.findPathNodeToNode, fromNodes, toNodes, modes)
	if not ok then
		return nil, tostring(result)
	end
	local found = result as {any}
	-- Plain copies: the card keeps the path across steps, and an engine view kept that long can read empty.
	local edges : {{EdgeId, boolean}} = {}
	for i = 1, found and #found or 0 do
		edges[#edges + 1] = route_state.edgeOf(found[i])
	end
	if #edges == 0 then
		return nil, "prc_note_no_path"
	end
	return edges, nil
end

-- The terminal of a line stop, with the node where the vehicle stops and the nodes where persons wait.
local function terminalOfStop(line : Engine.Entity, stopIndex : integer) : Terminal
	local lineComp = component(line, api.type.ComponentType.LINE) as Engine.Component.Line
	local stop = lineComp and lineComp.stops and lineComp.stops[stopIndex + 1]
	local station = stop and component(route_state.stationOfStop(line, stopIndex), api.type.ComponentType.STATION) as Station
	return station and station.terminals and station.terminals[(stop.terminal or 0) + 1]
end

-- Adds the nodes of the edges of a transport network that allow a transport mode.
local function appendNodes(nodes : {NodeId}, networkEntity : Engine.Entity, mode : TransportMode)
	local network = component(networkEntity, api.type.ComponentType.TRANSPORT_NETWORK) as Engine.Component.TransportNetwork
	for i = 1, network and #network.edges or 0 do
		local edge = network.edges[i]
		if edge.transportModes[mode] then
			for c = 1, #edge.conns do
				nodes[#nodes + 1] = edge.conns[c]
			end
		end
	end
end

route_lines.buildingNodes = function(entity : Engine.Entity, mode : TransportMode) : {NodeId}
	local nodes : {NodeId} = {}
	pcall(function()
		local building = component(entity, api.type.ComponentType.TOWN_BUILDING) as Engine.Component.TownBuilding
		-- The type definitions of the game do not list the component type of a parcel; the enum of the game has it.
		local parcelKind = (api.type.ComponentType as {string : Engine.ComponentType})["PARCEL"]
		local seen : {Engine.Entity : boolean} = {}
		for i = 1, #building.parcels do
			local parcel = component(building.parcels[i], parcelKind) as Engine.Component.Parcel
			local street = parcel and parcel.streetSegment
			if street ~= nil and street >= 0 and not seen[street] then
				seen[street] = true
				appendNodes(nodes, street, mode)
			end
		end
	end)
	return nodes
end

route_lines.stationNodes = function(station : Engine.Entity) : {NodeId}
	if batch ~= nil and batch.stationNodes[station] ~= nil then
		return batch.stationNodes[station]
	end
	local nodes : {NodeId} = {}
	pcall(function()
		local person = api.type["enum"].TransportMode.PERSON
		local reach = station2edges()[station]
		local nearest : Edge
		local nearestDistance : number
		for i = 1, #reach do
			local edgeId, distance = reach[i][1] as EdgeId, reach[i][2] as number
			if (nearestDistance == nil or distance < nearestDistance) and component(edgeId.entity, api.type.ComponentType.BASE_EDGE) ~= nil then
				local network = component(edgeId.entity, api.type.ComponentType.TRANSPORT_NETWORK) as Engine.Component.TransportNetwork
				local edge = network and network.edges[edgeId.index + 1]
				if edge and edge.transportModes[person] then
					nearest, nearestDistance = edge, distance
				end
			end
		end
		for c = 1, nearest and #nearest.conns or 0 do
			nodes[#nodes + 1] = nearest.conns[c]
		end
	end)
	if batch ~= nil then
		batch.stationNodes[station] = nodes
	end
	return nodes
end

-- The person nodes of the terminals of a station: the places where a person waits for a vehicle.
local function platformNodes(station : Engine.Entity) : {NodeId}
	if batch ~= nil and batch.platformNodes[station] ~= nil then
		return batch.platformNodes[station]
	end
	local nodes : {NodeId} = {}
	pcall(function()
		local terminals = (component(station, api.type.ComponentType.STATION) as Station).terminals
		for t = 1, #terminals do
			local personNodes = terminals[t].personNodes
			for n = 1, personNodes and #personNodes or 0 do
				nodes[#nodes + 1] = personNodes[n]
			end
		end
	end)
	if batch ~= nil then
		batch.platformNodes[station] = nodes
	end
	return nodes
end

local LOG_PREFIX <const> = "[PersonRoute] "
local entranceErrorLogged = false

-- The entrances of the stations read so far, as entity and index of each street node. Reading them walks over every edge
-- of the networks of a station, so they are kept until route_lines.forgetEntrances.
local entranceCache : {Engine.Entity : {{integer}}} = {}

route_lines.forgetEntrances = function()
	entranceCache = {}
end

-- The street nodes at the entrances of a station: the person nodes of every street edge that a link of the game joins to
-- an edge of a network with a platform of the station. Empty when the game lists no such link.
local function entranceNodes(station : Engine.Entity) : {NodeId}
	if batch ~= nil and batch.entranceNodes[station] ~= nil then
		return batch.entranceNodes[station]
	end
	local nodes : {NodeId} = {}
	local cached = entranceCache[station]
	if cached ~= nil then
		for i, pair in ipairs(cached) do
			nodes[i] = api.type.NodeId.new(pair[1], pair[2])
		end
	else
		local ok, message = pcall(function()
			local person = api.type["enum"].TransportMode.PERSON
			-- The type definitions of the game do not list the component type of a link; the enum of the game has it.
			local linkKind = (api.type.ComponentType as {string : Engine.ComponentType})["TP_NET_LINK"]
			local networks : {Engine.Entity} = {}
			local own : {Engine.Entity : boolean} = {}
			for __, node in ipairs(platformNodes(station)) do
				if not own[node.entity] then
					own[node.entity] = true
					networks[#networks + 1] = node.entity
				end
			end
			local seen : {string : boolean} = {}
			local function addStreet(edgeId : EdgeId)
				local key = tostring(edgeId.entity) .. ":" .. tostring(edgeId.index)
				if seen[key] or own[edgeId.entity] or component(edgeId.entity, api.type.ComponentType.BASE_EDGE) == nil then
					return
				end
				seen[key] = true
				local street = component(edgeId.entity, api.type.ComponentType.TRANSPORT_NETWORK) as Engine.Component.TransportNetwork
				local edge = street and street.edges[edgeId.index + 1]
				if edge and edge.transportModes[person] then
					for c = 1, #edge.conns do
						nodes[#nodes + 1] = edge.conns[c]
					end
				end
			end
			for __, networkEntity in ipairs(networks) do
				local network = component(networkEntity, api.type.ComponentType.TRANSPORT_NETWORK) as Engine.Component.TransportNetwork
				for i = 1, network and #network.edges or 0 do
					local edge = network.edges[i]
					if edge.transportModes[person] and edge.linkable ~= 0 then
						local links = api.engine.system.tpNetLinkSystem.getLinkEntities(api.type.EdgeId.new(networkEntity, i - 1))
						for l = 1, links and #links or 0 do
							local link = component(links[l], linkKind) as Engine.Component.TpNetLink
							if link ~= nil then
								addStreet(link.from.edgeId)
								addStreet(link.to.edgeId)
							end
						end
					end
				end
			end
		end as function() : any)
		if ok then
			local plain : {{integer}} = {}
			for i, node in ipairs(nodes) do
				plain[i] = { node.entity, node.index }
			end
			entranceCache[station] = plain
		elseif not entranceErrorLogged then
			entranceErrorLogged = true
			print(LOG_PREFIX .. "entrances of station " .. tostring(station) .. " not readable: " .. tostring(message))
		end
	end
	if batch ~= nil then
		batch.entranceNodes[station] = nodes
	end
	return nodes
end

local function pathMeters(edges : {{EdgeId, boolean}}) : number
	local meters = 0.0
	for __, pair in ipairs(edges) do
		local network = component(pair[1].entity, api.type.ComponentType.TRANSPORT_NETWORK) as Engine.Component.TransportNetwork
		local edge = network and network.edges and network.edges[pair[1].index + 1]
		meters = meters + (edge and edge.geometry and edge.geometry.length or 0)
	end
	return meters
end

-- The path of a walk. The pathfinder gives paths of different lengths for the two directions of the same walk, so both
-- are asked and the shorter one counts. A station end is the street edges at the entrances of the station; the
-- pathfinder gives no path from a platform of such a station. A station without a known entrance is first its platforms,
-- then the street edge nearest to it.
local function walkPath(leg : PrcRouteLeg) : {{EdgeId, boolean}}
	local person = api.type["enum"].TransportMode.PERSON
	local byEntrance = false
	local function find(nodesWithoutEntrance : function(Engine.Entity) : {NodeId}) : {{EdgeId, boolean}}
		local function stationEnd(station : Engine.Entity) : {NodeId}
			local nodes = entranceNodes(station)
			if #nodes > 0 then
				byEntrance = true
				return nodes
			end
			return nodesWithoutEntrance(station)
		end
		local from = leg.fromBuilding ~= nil and route_lines.buildingNodes(leg.fromBuilding, person) or stationEnd(leg.fromStation)
		local to = leg.toBuilding ~= nil and route_lines.buildingNodes(leg.toBuilding, person) or stationEnd(leg.toStation)
		local forward = route_lines.findPath(from, to, { person })
		local backward = route_lines.findPath(to, from, { person })
		if forward == nil or (backward ~= nil and pathMeters(backward) < pathMeters(forward)) then
			return backward
		end
		return forward
	end
	local edges = find(platformNodes)
	local byPlatform = edges ~= nil
	if edges == nil then
		edges = find(route_lines.stationNodes)
	end
	if edges ~= nil and batch ~= nil then
		if byEntrance then
			batch.entranceWalks = batch.entranceWalks + 1
		elseif byPlatform then
			batch.platformWalks = batch.platformWalks + 1
		else
			batch.nearestWalks = batch.nearestWalks + 1
		end
	end
	return edges
end

route_lines.legPath = function(leg : PrcRouteLeg) : {{EdgeId, boolean}}
	if leg.edges ~= nil then
		return leg.edges
	end
	local edges : {{EdgeId, boolean}} = {}
	local ok = pcall(function()
		if leg.line == nil then
			edges = walkPath(leg) or {}
			return
		end
		local lineComp = component(leg.line, api.type.ComponentType.LINE) as Engine.Component.Line
		local modes : {TransportMode} = {}
		for mode, allowed in pairs(lineComp.vehicleInfo.transportModes) do
			if allowed then
				modes[#modes + 1] = mode
			end
		end
		local count = #lineComp.stops
		local stop = leg.fromStopIndex
		for __ = 1, count do
			if stop == leg.toStopIndex then
				break
			end
			local nextStop = (stop + 1) % count
			local section = route_lines.findPath({ terminalOfStop(leg.line, stop).vehicleNodeId }, { terminalOfStop(leg.line, nextStop).vehicleNodeId }, modes)
			if section == nil then
				error("no path for a section of the line")
			end
			for __, pair in ipairs(section) do
				edges[#edges + 1] = pair
			end
			stop = nextStop
		end
	end)
	if not ok or #edges == 0 then
		return nil
	end
	return edges
end

-- The network of the stations: a ride on a line from a stop to every later stop, and a walk between two stations in
-- reach of each other.
local function buildNetwork(walkSpeed : number) : Network
	local lineSystem = api.engine.system.lineSystem
	local speed = math.max(walkSpeed or 0, MIN_SPEED_MPS)
	local station2stations = api.engine.system.catchmentAreaSystem.getStation2stationsAndDistancesMap() or {}

	local lines : {Engine.Entity : LineInfo} = {}
	local function lineInfo(line : Engine.Entity) : LineInfo
		local info = lines[line]
		if info == nil then
			info = { stations = {}, times = sectionTimes(line), wait = route_lines.waitSeconds(line) }
			local comp = component(line, api.type.ComponentType.LINE) as Engine.Component.Line
			for i = 1, comp and comp.stops and #comp.stops or 0 do
				info.stations[i] = route_state.stationOfStop(line, i - 1)
			end
			lines[line] = info
		end
		return info
	end

	local outOf : {Engine.Entity : {NetEdge}} = {}
	local into : {Engine.Entity : {NetEdge}} = {}
	local function addEdge(edge : NetEdge)
		outOf[edge.from] = outOf[edge.from] or {}
		into[edge.to] = into[edge.to] or {}
		local out, inn = outOf[edge.from], into[edge.to]
		out[#out + 1] = edge
		inn[#inn + 1] = edge
	end

	local stations : {Engine.Entity} = {}
	for station, __ in pairs(station2edges()) do
		stations[#stations + 1] = station
	end
	table.sort(stations)
	for __, station in ipairs(stations) do
		for __, lineAndStop in ipairs(lineSystem.getLineStopsForStation(station) or {}) do
			local line, stop = lineAndStop[1], lineAndStop[2]
			local info = lineInfo(line)
			local count = #info.stations
			local ride = 0.0
			for step = 1, info.times and count - 1 or 0 do
				ride = ride + (info.times[(stop + step - 1) % count + 1] or 0)
				local toStop = (stop + step) % count
				local to = info.stations[toStop + 1]
				if to ~= nil and to ~= station then
					addEdge({
						from = station,
						to = to,
						cost = ride + (info.wait or 0),
						leg = { line = line, fromStation = station, toStation = to, fromStopIndex = stop, toStopIndex = toStop, seconds = ride, waitSeconds = info.wait },
					})
				end
			end
		end
		for other, distance in pairs(station2stations[station] or {}) do
			if other ~= station then
				local leg : PrcRouteLeg = { fromStation = station, toStation = other, seconds = distance / speed }
				addEdge({ from = station, to = other, cost = leg.seconds, leg = leg })
			end
		end
	end
	return { outOf = outOf, into = into, station2stations = station2stations, speed = speed }
end

route_lines.search = function(targetStations : {Engine.Entity}, walkSpeed : number) : PrcLineSearch
	local network = batch and batch.network or buildNetwork(walkSpeed)
	if batch ~= nil then
		batch.network = network
	end
	local outOf, into, station2stations = network.outOf, network.into, network.station2stations
	local function walkLeg(from : Engine.Entity, to : Engine.Entity, distance : number) : PrcRouteLeg
		return { fromStation = from, toStation = to, seconds = distance / network.speed }
	end

	-- The cost from every station to the nearest target station, and the first edge of that route.
	local cost : {Engine.Entity : number} = {}
	local nextEdge : {Engine.Entity : NetEdge} = {}
	local done : {Engine.Entity : boolean} = {}
	for __, station in ipairs(targetStations) do
		cost[station] = 0
	end
	while true do
		local nearest : Engine.Entity = nil
		for station, value in pairs(cost) do
			if not done[station] and (nearest == nil or value < cost[nearest] or (value == cost[nearest] and station < nearest)) then
				nearest = station
			end
		end
		if nearest == nil then
			break
		end
		done[nearest] = true
		for __, edge in ipairs(into[nearest] or {}) do
			local value = cost[nearest] + edge.cost
			if not done[edge.from] and (cost[edge.from] == nil or value < cost[edge.from]) then
				cost[edge.from] = value
				nextEdge[edge.from] = edge
			end
		end
	end

	local search : PrcLineSearch = {}

	search.routeFrom = function(station : Engine.Entity) : PrcLineEstimate
		if station == nil or cost[station] == nil then
			return nil
		end
		local legs : {PrcRouteLeg} = {}
		local current = station
		while nextEdge[current] ~= nil do
			legs[#legs + 1] = nextEdge[current].leg
			current = nextEdge[current].to
		end
		return { legs = legs, totalSeconds = cost[station] }
	end

	search.options = function(originStations : {Engine.Entity}, maxOptions : integer) : {PrcLineEstimate}
		local best : {Engine.Entity : PrcLineEstimate} = {}
		local function offer(start : PrcRouteLeg, startCost : number, station : Engine.Entity)
			for __, edge in ipairs(outOf[station] or {}) do
				if edge.leg.line ~= nil and cost[edge.to] ~= nil then
					local total = startCost + edge.cost + cost[edge.to]
					local current = best[edge.leg.line]
					if current == nil or total < current.totalSeconds then
						local legs : {PrcRouteLeg} = {}
						if start ~= nil then
							legs[#legs + 1] = start
						end
						legs[#legs + 1] = edge.leg
						for __, leg in ipairs(search.routeFrom(edge.to).legs) do
							legs[#legs + 1] = leg
						end
						best[edge.leg.line] = { legs = legs, totalSeconds = total }
					end
				end
			end
		end
		for __, station in ipairs(originStations) do
			offer(nil, 0, station)
			for other, distance in pairs(station2stations[station] or {}) do
				if other ~= station then
					local leg = walkLeg(station, other, distance)
					offer(leg, leg.seconds, other)
				end
			end
		end

		local options : {PrcLineEstimate} = {}
		for __, option in pairs(best) do
			options[#options + 1] = option
		end
		table.sort(options, function(a : PrcLineEstimate, b : PrcLineEstimate) : boolean
			if a.totalSeconds ~= b.totalSeconds then
				return a.totalSeconds < b.totalSeconds
			end
			local lineA, lineB : Engine.Entity, Engine.Entity
			for __, leg in ipairs(a.legs) do
				lineA = lineA or leg.line
			end
			for __, leg in ipairs(b.legs) do
				lineB = lineB or leg.line
			end
			return lineA < lineB
		end)
		while #options > maxOptions do
			options[#options] = nil
		end
		return options
	end

	return search
end

return route_lines
