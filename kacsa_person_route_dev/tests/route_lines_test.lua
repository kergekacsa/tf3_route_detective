-- Tests of route_lines.tl: the shortest routes by lines over the stations of the map.

local support = dofile((arg[0]:match("^(.*)[/\\][^/\\]*$") or ".") .. "/support.lua")
local check, near = support.check, support.near

support.installRequire()

-- Stations S1..S6. Line A: S1 -> S2 -> S3. Line B: S4 -> S5. Line C: S5 -> S6. Line SLOW: S1 -> S6 directly.
-- S3 and S4 are 150 m apart on foot. Every line returns to its first stop after its last one.
-- Line LOOP: LA -> LB -> LC -> LB, so it stops at LB twice in one round.
local S1, S2, S3, S4, S5, S6, S_LONELY = 11, 12, 13, 14, 15, 16, 17
local LA, LB, LC = 18, 19, 20
local LINE_A, LINE_B, LINE_C, LINE_SLOW, LINE_EMPTY, LINE_LOOP = 60, 61, 62, 63, 64, 65
local GROUP = 70
local WALK_SPEED = 1.5
local STREET = 2000
local HOME, SHARED = 9000, 9999
local BUILDING, PARCEL, PARCEL_SAME_STREET, PARCEL_GONE = 80, 81, 82, 83
local FREQUENCY = 1 / 600

local stationsOfLine = {
  [LINE_A] = { S1, S2, S3 },
  [LINE_B] = { S4, S5 },
  [LINE_C] = { S5, S6 },
  [LINE_SLOW] = { S1, S6 },
  [LINE_EMPTY] = { S1, S6 },
  [LINE_LOOP] = { LA, LB, LC, LB },
}
local sectionTimes = {
  [LINE_A] = { 100, 50, 150 },
  [LINE_B] = { 200, 200 },
  [LINE_C] = { 40, 40 },
  [LINE_SLOW] = { 5000, 5000 },
  [LINE_LOOP] = { 60, 70, 70, 60 },
}
local allStations = { S1, S2, S3, S4, S5, S6, S_LONELY, LA, LB, LC }

local pathCalls
local mapCalls

local function install(wire)
  local world = { [support.WORLD] = { GAME_TIME = { gameTime = 0 } }, [GROUP] = { STATION_GROUP = { stations = allStations } } }
  for _, station in ipairs(allStations) do
    world[station] = { STATION = { terminals = { { vehicleNodeId = { entity = station, index = 0 }, personNodes = { { entity = station, index = 1 } } } } } }
    local street = STREET + station
    world[street] = { BASE_EDGE = {}, TRANSPORT_NETWORK = { edges = {
      { conns = { { entity = street, index = 0 }, { entity = street, index = 1 } }, transportModes = { [0] = true } },
      { conns = { { entity = street, index = 2 }, { entity = street, index = 3 } }, transportModes = { [2] = true } },
    } } }
  end
  world[BUILDING] = { TOWN_BUILDING = { parcels = { PARCEL, PARCEL_SAME_STREET, PARCEL_GONE } } }
  world[PARCEL] = { PARCEL = { streetSegment = STREET + S1 } }
  world[PARCEL_SAME_STREET] = { PARCEL = { streetSegment = STREET + S1 } }
  local indexOf = {}
  for i, station in ipairs(allStations) do indexOf[station] = i - 1 end
  for line, stations in pairs(stationsOfLine) do
    local stops = {}
    for i, station in ipairs(stations) do stops[i] = { stationGroup = GROUP, station = indexOf[station], terminal = 0 } end
    world[line] = { LINE = { stops = stops, vehicleInfo = { transportModes = { [0] = false, [3] = true } } } }
    world[1000 + line] = { TRANSPORT_VEHICLE = { sectionTimes = sectionTimes[line] } }
  end
  local api = support.installApi(world)
  mapCalls = 0
  api.engine.system.catchmentAreaSystem.getStation2edgesMap = function()
    mapCalls = mapCalls + 1
    local map = {}
    for _, station in ipairs(allStations) do
      map[station] = { { { entity = station, index = 0 }, 1 }, { { entity = STREET + station, index = 1 }, 2 }, { { entity = STREET + station, index = 0 }, 3 } }
    end
    return map
  end
  -- Every station catches its own building, and stations S1 and S2 share one more.
  api.engine.system.catchmentAreaSystem.getStationCatchables = function(station, cargo)
    assert(cargo == false, "persons, not cargo")
    if station == S1 or station == S2 then return { HOME + station, SHARED } end
    return { HOME + station }
  end
  api.engine.system.catchmentAreaSystem.getStation2stationsAndDistancesMap = function()
    return { [S3] = { [S3] = 0, [S4] = 150 }, [S4] = { [S3] = 150 } }
  end
  api.engine.system.lineSystem.getLineStopsForStation = function(station)
    local result = {}
    for _, line in ipairs({ LINE_A, LINE_B, LINE_C, LINE_SLOW, LINE_EMPTY, LINE_LOOP }) do
      for i, at in ipairs(stationsOfLine[line]) do
        if at == station then result[#result + 1] = { line, i - 1 } end
      end
    end
    return result
  end
  api.engine.system.transportVehicleSystem.getLineVehicles = function(line)
    if sectionTimes[line] then return { 1000 + line } end
    return {}
  end
  api.engine.util.line.getMaxFrequency = function(line) return FREQUENCY end
  -- A path of one edge that names the two nodes it joins: the entity of the start node and the entity of the end node.
  pathCalls = {}
  api.engine.util.pathfinding.findPathNodeToNode = function(fromNodes, toNodes, modes)
    pathCalls[#pathCalls + 1] = { from = fromNodes, to = toNodes, modes = modes }
    return { { { entity = fromNodes[1].entity, index = toNodes[1].entity }, true } }
  end
  if wire then wire(api) end
  -- The module is loaded once for all tests, so what it keeps between computations is dropped here.
  local module = ug_require("kacsa_person_route::/person_route/route_lines.tl")
  module.forgetEntrances()
  return module
end

local route_lines = install()

-- Ride seconds
check("ride: one section", near(route_lines.rideSeconds(LINE_A, 0, 1), 100))
check("ride: two sections", near(route_lines.rideSeconds(LINE_A, 0, 2), 150))
check("ride: wraps around the end of the line", near(route_lines.rideSeconds(LINE_A, 2, 1), 250))
check("ride: same stop is zero", near(route_lines.rideSeconds(LINE_A, 1, 1), 0))
check("ride: a line without vehicles gives nil", route_lines.rideSeconds(LINE_EMPTY, 0, 1) == nil)

-- Routes to S6
local search = route_lines.search({ S6 }, WALK_SPEED)
local route = search.routeFrom(S6)
check("route from a target: no legs, no time", route ~= nil and #route.legs == 0 and near(route.totalSeconds, 0))
check("route from a station without a way: nil", search.routeFrom(S_LONELY) == nil and search.routeFrom(nil) == nil)

route = search.routeFrom(S5)
check("one ride: wait 300 + ride 40", #route.legs == 1 and route.legs[1].line == LINE_C and near(route.totalSeconds, 340))
check("one ride: stations and stops of the leg", route.legs[1].fromStation == S5 and route.legs[1].toStation == S6
  and route.legs[1].fromStopIndex == 0 and route.legs[1].toStopIndex == 1 and near(route.legs[1].seconds, 40) and near(route.legs[1].waitSeconds, 300))

route = search.routeFrom(S3)
check("walk then two lines: three legs", #route.legs == 3 and route.legs[1].line == nil and route.legs[2].line == LINE_B and route.legs[3].line == LINE_C)
check("walk leg: from, to, and 150 m at the walk speed", route.legs[1].fromStation == S3 and route.legs[1].toStation == S4 and near(route.legs[1].seconds, 100)
  and route.legs[1].waitSeconds == nil)
check("walk then two lines: total", near(route.totalSeconds, 100 + 300 + 200 + 300 + 40))

route = search.routeFrom(S1)
check("three lines beat the slow direct line", #route.legs == 4 and route.legs[1].line == LINE_A and route.legs[1].toStation == S3
  and near(route.totalSeconds, 300 + 150 + 940))
check("a ride over two sections is one leg with one wait", route.legs[1].fromStopIndex == 0 and route.legs[1].toStopIndex == 2 and near(route.legs[1].seconds, 150))

-- Options from S1: one per first line, the best first
local options = search.options({ S1 }, 5)
check("options: one per line with a vehicle at the origin", #options == 2 and options[1].legs[1].line == LINE_A and options[2].legs[1].line == LINE_SLOW)
check("options: totals", near(options[1].totalSeconds, 1390) and near(options[2].totalSeconds, 300 + 5000))
check("options: the cap", #search.options({ S1 }, 1) == 1)
check("options: none from a station without lines", #search.options({ S_LONELY }, 5) == 0)

-- An origin station without lines, in walking reach of a station with lines
options = search.options({ S3 }, 5)
check("options: line A at the origin loops round, line B is reached on foot and comes first", #options == 2 and options[1].legs[1].line == nil
  and options[1].legs[1].toStation == S4 and options[1].legs[2].line == LINE_B and near(options[1].totalSeconds, 940))

-- A line without frequency
route_lines = install(function(api)
  api.engine.util.line.getMaxFrequency = function(line) return 0 end
end)
search = route_lines.search({ S6 }, WALK_SPEED)
route = search.routeFrom(S5)
check("no frequency: no wait in the leg and in the total", route.legs[1].waitSeconds == nil and near(route.totalSeconds, 40))

-- No target station
search = route_lines.search({}, WALK_SPEED)
check("no targets: no route, no options", search.routeFrom(S1) == nil and #search.options({ S1 }, 5) == 0)

-- The pathfinder wrapper
route_lines = install()
local edges, note = route_lines.findPath({}, { { entity = 1, index = 0 } }, { 0 })
check("findPath: no nodes", edges == nil and note == "prc_note_no_nodes")
edges, note = route_lines.findPath({ { entity = 1, index = 0 } }, { { entity = 2, index = 0 } }, { 0 })
check("findPath: plain copies of the edges", #edges == 1 and edges[1][1].entity == 1 and edges[1][1].index == 2 and edges[1][2] == true and note == nil)
route_lines = install(function(api)
  api.engine.util.pathfinding.findPathNodeToNode = function(fromNodes) if fromNodes[1].entity == S2 then return {} end error("bad nodes") end
end)
edges, note = route_lines.findPath({ { entity = 1, index = 0 } }, { { entity = 2, index = 0 } }, { 0 })
check("findPath: the message of a failed call", edges == nil and note:find("bad nodes", 1, true) ~= nil)
edges, note = route_lines.findPath({ { entity = S2, index = 0 } }, { { entity = 2, index = 0 } }, { 0 })
check("findPath: an empty result", edges == nil and note == "prc_note_no_path")

-- The path of a leg
route_lines = install()
edges = route_lines.legPath({ line = LINE_A, fromStopIndex = 0, toStopIndex = 2 })
check("leg path: one section per stop, between the vehicle nodes of the stops", #edges == 2 and edges[1][1].entity == S1 and edges[1][1].index == S2
  and edges[2][1].entity == S2 and edges[2][1].index == S3 and pathCalls[1].from[1].index == 0)
check("leg path: the modes of the line", #pathCalls[1].modes == 1 and pathCalls[1].modes[1] == 3)
edges = route_lines.legPath({ line = LINE_A, fromStopIndex = 2, toStopIndex = 0 })
check("leg path: wraps around the end of the line", #edges == 1 and edges[1][1].entity == S3 and edges[1][1].index == S1)
pathCalls = {}
edges = route_lines.legPath({ fromStation = S3, toStation = S4 })
check("leg path: a walk between stations runs between the person nodes of their terminals, on foot", #edges == 1 and edges[1][1].entity == S3
  and edges[1][1].index == S4 and #pathCalls[1].from == 1 and pathCalls[1].from[1].index == 1 and pathCalls[1].modes[1] == 0)
check("leg path: a walk is asked in both directions", #pathCalls == 2 and pathCalls[2].from[1].entity == S4 and pathCalls[2].to[1].entity == S3)
pathCalls = {}
edges = route_lines.legPath({ fromBuilding = BUILDING, toStation = S4 })
check("leg path: a walk from a building starts at the street of its parcels and ends at a platform", #edges == 1 and edges[1][1].entity == STREET + S1
  and edges[1][1].index == S4)
edges = route_lines.legPath({ fromStation = S4, toBuilding = BUILDING })
check("leg path: a walk to a building starts at a platform and ends at the street of its parcels", #edges == 1 and edges[1][1].entity == S4
  and edges[1][1].index == STREET + S1)
local known = { { { entity = 1, index = 2 }, true } }
check("leg path: the edges a leg carries are returned as they are", route_lines.legPath({ fromStation = S4, toBuilding = BUILDING, edges = known }) == known)

-- The nodes of a building and of a station
local nodes = route_lines.buildingNodes(BUILDING, 0)
check("building nodes: the person nodes of the street, once per street", #nodes == 2 and nodes[1].entity == STREET + S1 and nodes[1].index == 0 and nodes[2].index == 1)
nodes = route_lines.buildingNodes(BUILDING, 2)
check("building nodes: the car nodes of the street", #nodes == 2 and nodes[1].index == 2 and nodes[2].index == 3)
check("building nodes: none for an entity without parcels", #route_lines.buildingNodes(S1, 0) == 0 and #route_lines.buildingNodes(999, 0) == 0)
nodes = route_lines.stationNodes(S2)
check("station nodes: the nearest street edge for persons, not the nearer edge of the station and not the car edge", #nodes == 2
  and nodes[1].entity == STREET + S2 and nodes[1].index == 0)
check("station nodes: none for an unknown station", #route_lines.stationNodes(999) == 0)
check("leg path: nil for an unknown line or station", route_lines.legPath({ line = 999, fromStopIndex = 0, toStopIndex = 1 }) == nil
  and route_lines.legPath({ fromStation = 998, toStation = 999 }) == nil)
route_lines = install(function(api)
  api.engine.util.pathfinding.findPathNodeToNode = function(fromNodes, toNodes)
    if fromNodes[1].entity == S2 then return {} end
    return { { { entity = fromNodes[1].entity, index = toNodes[1].entity }, true } }
  end
end)
check("leg path: nil when one section has no path", route_lines.legPath({ line = LINE_A, fromStopIndex = 0, toStopIndex = 2 }) == nil)

-- No path from or to a platform: the walk uses the street edge nearest to the station
route_lines = install(function(api)
  api.engine.util.pathfinding.findPathNodeToNode = function(fromNodes, toNodes, modes)
    pathCalls[#pathCalls + 1] = { from = fromNodes, to = toNodes, modes = modes }
    if fromNodes[1].entity < STREET or toNodes[1].entity < STREET then return {} end
    return { { { entity = fromNodes[1].entity, index = toNodes[1].entity }, true } }
  end
end)
local platformWalks, entranceWalks, nearestWalks = route_lines.batch(function()
  edges = route_lines.legPath({ fromStation = S3, toStation = S4 })
end)
check("leg path: without a path between platforms, the walk runs between the nearest street edges", #edges == 1 and edges[1][1].entity == STREET + S3
  and edges[1][1].index == STREET + S4 and #pathCalls == 4 and #pathCalls[3].from == 2)
check("batch: counts the walk by the nearest street", platformWalks == 0 and entranceWalks == 0 and nearestWalks == 1)

-- Station S3 has links to two streets: its entrances. A link to a car edge and a link inside the station do not count.
local LINK_A, LINK_B, LINK_CAR, LINK_OWN = 3001, 3002, 3003, 3004
local linkQueries = 0
route_lines = install(function(api)
  local get = api.engine.getComponent
  local own = { entity = S3, index = 0 }
  local links = {
    [LINK_A] = { from = { edgeId = own, param = 0 }, to = { edgeId = { entity = STREET + S5, index = 0 }, param = 0.5 } },
    [LINK_B] = { from = { edgeId = { entity = STREET + S6, index = 0 }, param = 0.5 }, to = { edgeId = own, param = 1 } },
    [LINK_CAR] = { from = { edgeId = own, param = 0 }, to = { edgeId = { entity = STREET + S5, index = 1 }, param = 0.5 } },
    [LINK_OWN] = { from = { edgeId = own, param = 0 }, to = { edgeId = { entity = S3, index = 1 }, param = 0 } },
  }
  api.engine.getComponent = function(entity, kind)
    if entity == S3 and kind == "TRANSPORT_NETWORK" then
      return { edges = { { transportModes = { [0] = true }, linkable = 1 }, { transportModes = { [0] = true }, linkable = 0 } } }
    end
    if kind == "TP_NET_LINK" then return links[entity] end
    return get(entity, kind)
  end
  api.engine.system.tpNetLinkSystem.getLinkEntities = function(edgeId)
    assert(edgeId.entity == S3 and edgeId.index == 0, "only the linkable edge of the station is asked")
    linkQueries = linkQueries + 1
    return { LINK_A, LINK_B, LINK_CAR, LINK_OWN }
  end
  api.engine.util.pathfinding.findPathNodeToNode = function(fromNodes, toNodes, modes)
    pathCalls[#pathCalls + 1] = { from = fromNodes, to = toNodes, modes = modes }
    if fromNodes[1].entity < STREET or toNodes[1].entity < STREET then return {} end
    return { { { entity = fromNodes[1].entity, index = toNodes[1].entity }, true } }
  end
end)
platformWalks, entranceWalks, nearestWalks = route_lines.batch(function()
  edges = route_lines.legPath({ fromStation = S3, toStation = S4 })
end)
check("entrances: the walk starts at the street edges that links join to the station", #edges == 1 and edges[1][1].entity == STREET + S5
  and #pathCalls[3].from == 4 and pathCalls[3].from[3].entity == STREET + S6 and pathCalls[3].from[1].index == 0)
check("entrances: the other station is first its platform, then its nearest street edge", #pathCalls[1].to == 1 and pathCalls[1].to[1].entity == S4
  and edges[1][1].index == STREET + S4 and #pathCalls[3].to == 2)
check("batch: counts the walk by entrance", platformWalks == 0 and entranceWalks == 1 and nearestWalks == 0)
route_lines.batch(function()
  edges = route_lines.legPath({ fromStation = S3, toStation = S4 })
end)
check("entrances: read once and kept for the next computation", linkQueries == 1 and edges[1][1].entity == STREET + S5)
route_lines.forgetEntrances()
route_lines.batch(function()
  route_lines.legPath({ fromStation = S3, toStation = S4 })
end)
check("entrances: read again after they are forgotten", linkQueries == 2)

-- The two directions of a walk give paths of different lengths: the shorter one counts
route_lines = install(function(api)
  local get = api.engine.getComponent
  api.engine.getComponent = function(entity, kind)
    if entity == 4000 and kind == "TRANSPORT_NETWORK" then
      return { edges = { { geometry = { length = 300 } }, { geometry = { length = 100 } } } }
    end
    return get(entity, kind)
  end
  api.engine.util.pathfinding.findPathNodeToNode = function(fromNodes)
    return { { { entity = 4000, index = fromNodes[1].entity == S3 and 0 or 1 }, true } }
  end
end)
edges = route_lines.legPath({ fromStation = S3, toStation = S4 })
check("both directions: the path from the far end is shorter and counts", #edges == 1 and edges[1][1].index == 1)
edges = route_lines.legPath({ fromStation = S4, toStation = S3 })
check("both directions: the forward path is shorter and counts", #edges == 1 and edges[1][1].index == 1)

route_lines = install()
platformWalks, entranceWalks, nearestWalks = route_lines.batch(function()
  route_lines.legPath({ fromStation = S3, toStation = S4 })
  route_lines.legPath({ fromBuilding = BUILDING, toStation = S4 })
end)
check("batch: two walks by platform", platformWalks == 2 and entranceWalks == 0 and nearestWalks == 0)

-- Stations in reach
route_lines = install()
local reach = route_lines.stationsInReach({ HOME + S3 })
check("stations: the station whose catchables hold the building", #reach == 1 and reach[1] == S3)
reach = route_lines.stationsInReach({ SHARED })
check("stations: every station that catches the building, in order", #reach == 2 and reach[1] == S1 and reach[2] == S2)
reach = route_lines.stationsInReach({ SHARED, HOME + S1, HOME + S4 })
check("stations: of several entities, each station once", #reach == 3 and reach[3] == S4)
check("stations: none for a stranger", #route_lines.stationsInReach({ 12345 }) == 0)
check("stations: -1 and nil are ignored", #route_lines.stationsInReach({ -1, nil }) == 0)

-- One fetch of the big maps for a whole batch
route_lines = install()
route_lines.stationNodes(S1)
route_lines.stationNodes(S2)
check("batch: without a batch every call fetches the catchment map", mapCalls == 2)
mapCalls = 0
local inside
route_lines.batch(function()
  route_lines.stationsInReach({ HOME + S1 })
  route_lines.stationNodes(S1)
  route_lines.stationNodes(S1)
  route_lines.search({ S6 }, WALK_SPEED)
  inside = route_lines.search({ S5 }, WALK_SPEED).routeFrom(S4)
end)
check("batch: the catchment map is fetched once for stations, nodes, and two searches", mapCalls == 1, mapCalls)
check("batch: the second search uses the network of the first and still finds its own route", inside ~= nil and #inside.legs == 1 and inside.legs[1].line == LINE_B)
route_lines.stationNodes(S1)
check("batch: after the batch the data is fetched again", mapCalls == 2)
local okBatch, message = pcall(route_lines.batch, function() error("inside the batch") end)
mapCalls = 0
route_lines.stationNodes(S1)
check("batch: an error leaves the batch and reaches the caller", okBatch == false and tostring(message):find("inside the batch", 1, true) ~= nil and mapCalls == 1)

-- A line that stops at one station twice in one round
route_lines = install()
search = route_lines.search({ LC }, WALK_SPEED)
route = search.routeFrom(LB)
check("station twice on a line: the ride starts at the visit before the target", #route.legs == 1 and route.legs[1].fromStopIndex == 1
  and route.legs[1].toStopIndex == 2 and near(route.legs[1].seconds, 70))
options = search.options({ LB }, 5)
check("station twice on a line: the option starts at the visit before the target", #options == 1 and options[1].legs[1].fromStopIndex == 1
  and options[1].legs[1].toStopIndex == 2)

-- The same line when its vehicle has no section times yet, and the game lists the later visit first
local measured = sectionTimes[LINE_LOOP]
sectionTimes[LINE_LOOP] = { 0, 0, 0, 0 }
route_lines = install(function(api)
  local inOrder = api.engine.system.lineSystem.getLineStopsForStation
  api.engine.system.lineSystem.getLineStopsForStation = function(station)
    local stops, reversed = inOrder(station), {}
    for i = #stops, 1, -1 do reversed[#reversed + 1] = stops[i] end
    return reversed
  end
end)
search = route_lines.search({ LC }, WALK_SPEED)
route = search.routeFrom(LB)
check("equal times: the route takes the ride over fewer sections", #route.legs == 1 and route.legs[1].fromStopIndex == 1
  and route.legs[1].toStopIndex == 2, route.legs[1] and route.legs[1].fromStopIndex)
options = search.options({ LB }, 5)
check("equal times: the option takes the ride over fewer sections", #options == 1 and options[1].legs[1].fromStopIndex == 1
  and options[1].legs[1].toStopIndex == 2, options[1] and options[1].legs[1].fromStopIndex)
sectionTimes[LINE_LOOP] = measured

support.finish("route_lines")
