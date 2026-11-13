-- Tests of route_compare.tl: the options of a trip, with the route of the game for the option the game chose.

local support = dofile((arg[0]:match("^(.*)[/\\][^/\\]*$") or ".") .. "/support.lua")
local check, near = support.check, support.near

support.installRequire()

local PERSON = 100
local ORIGIN, TARGET = 10, 20
local NETWORK = 500
local STREET_O, STREET_T = 600, 601
local PARCEL_O, PARCEL_T = 610, 611
local STATION_O, STATION_T, STATION_FAR = 30, 31, 32
local LINE_SHARED = 40
local GROUP = 45
local VEHICLE = 50
local PERSON_MODE, CAR_MODE, BUS_MODE = 0, 2, 3
local WALK, DRIVE, LINES = 0, 1, 2

local function edge(index) return { entity = NETWORK, index = index } end

-- A street with one edge for persons (nodes 0 and 1) and one edge for cars (nodes 2 and 3).
local function street(entity)
  return {
    BASE_EDGE = {},
    TRANSPORT_NETWORK = { edges = {
      { conns = { { entity = entity, index = 0 }, { entity = entity, index = 1 } }, transportModes = { [PERSON_MODE] = true } },
      { conns = { { entity = entity, index = 2 }, { entity = entity, index = 3 } }, transportModes = { [CAR_MODE] = true } },
    } },
  }
end

local function station(entity)
  return { STATION = { terminals = { { vehicleNodeId = { entity = entity, index = 0 } } } } }
end

local function baseWorld(person)
  return {
    [support.WORLD] = { GAME_TIME = { gameTime = 0 } },
    [PERSON] = person or { SIM_PERSON = { lastMoveMode = LINES, walkSpeed = 1.5 } },
    [ORIGIN] = { TOWN_BUILDING = { parcels = { PARCEL_O } } },
    [TARGET] = { TOWN_BUILDING = { parcels = { PARCEL_T } } },
    [PARCEL_O] = { PARCEL = { streetSegment = STREET_O } },
    [PARCEL_T] = { PARCEL = { streetSegment = STREET_T } },
    [STREET_O] = street(STREET_O),
    [STREET_T] = street(STREET_T),
    [NETWORK] = { TRANSPORT_NETWORK = { edges = {
      { geometry = { length = 100 }, speedLimit = 10, curveSpeedLimit = 0 },
      { geometry = { length = 50 }, speedLimit = 10, curveSpeedLimit = 0 },
      { geometry = { length = 300 }, speedLimit = 20, curveSpeedLimit = 15 },
      { geometry = { length = 200 }, speedLimit = 25, curveSpeedLimit = 30 },
    } } },
    [LINE_SHARED] = {
      LINE = {
        stops = { { stationGroup = GROUP, station = 0, terminal = 0 }, { stationGroup = GROUP, station = 1, terminal = 0 }, { stationGroup = GROUP, station = 2, terminal = 0 } },
        vehicleInfo = { transportModes = { [BUS_MODE] = true } },
      },
    },
    [GROUP] = { STATION_GROUP = { stations = { STATION_O, STATION_FAR, STATION_T } } },
    [STATION_O] = station(STATION_O),
    [STATION_FAR] = station(STATION_FAR),
    [STATION_T] = station(STATION_T),
    [VEHICLE] = { TRANSPORT_VEHICLE = { sectionTimes = { 60, 120, 180 } } },
  }
end

local function trip(fields)
  local state = { phase = "unknown", originEntity = ORIGIN, targetEntity = TARGET }
  for k, v in pairs(fields or {}) do state[k] = v end
  return state
end

local route_compare
local pathCalls
local mapCalls, catchableCalls

local function load(w, wire)
  local api = support.installApi(w)
  pathCalls = {}
  -- A walk is 150 m, a drive 500 m, a section of a bus line 300 m, whatever its ends.
  api.engine.util.pathfinding.findPathNodeToNode = function(fromNodes, toNodes, modes)
    pathCalls[#pathCalls + 1] = { from = fromNodes, to = toNodes, mode = modes[1] }
    if modes[1] == PERSON_MODE then
      return { { edge(0), true }, { edge(1), false } }
    elseif modes[1] == BUS_MODE then
      return { { edge(2), true } }
    end
    return { { edge(2), true }, { edge(3), true } }
  end
  -- The edge of the origin building is nearer to its station than the street, and it is no street.
  mapCalls, catchableCalls = 0, 0
  api.engine.system.catchmentAreaSystem.getStation2edgesMap = function()
    mapCalls = mapCalls + 1
    return {
      [STATION_O] = { { { entity = ORIGIN, index = 0 }, 1 }, { { entity = STREET_O, index = 1 }, 4 }, { { entity = STREET_O, index = 0 }, 5 } },
      [STATION_T] = { { { entity = STREET_T, index = 0 }, 7 } },
      [STATION_FAR] = { { { entity = STREET_T, index = 0 }, 9 } },
    }
  end
  api.engine.system.catchmentAreaSystem.getStationCatchables = function(stationEntity, cargo)
    assert(cargo == false, "persons, not cargo")
    catchableCalls = catchableCalls + 1
    if stationEntity == STATION_O then return { 7, ORIGIN } end
    if stationEntity == STATION_T then return { TARGET } end
    return { 999 }
  end
  api.engine.system.catchmentAreaSystem.getStation2stationsAndDistancesMap = function() return {} end
  api.engine.system.lineSystem.getLineStopsForStation = function(stationEntity)
    if stationEntity == STATION_O then return { { LINE_SHARED, 0 } } end
    if stationEntity == STATION_FAR then return { { LINE_SHARED, 1 } } end
    if stationEntity == STATION_T then return { { LINE_SHARED, 2 } } end
    return {}
  end
  api.engine.system.transportVehicleSystem.getLineVehicles = function(line)
    if line == LINE_SHARED then return { VEHICLE } end
    return {}
  end
  api.engine.util.line.getMaxFrequency = function(line) return 1 / 600 end
  if wire then wire(api) end
  route_compare = ug_require("kacsa_person_route::/person_route/route_compare.tl")
end

local function calls(mode)
  local count = 0
  for _, call in ipairs(pathCalls) do
    if call.mode == mode then count = count + 1 end
  end
  return count
end

-- The first option of a kind.
local function kind(result, name)
  for _, option in ipairs(result.options) do
    if option.kind == name then return option end
  end
  return nil
end

local function linesOptions(result)
  local found = {}
  for _, option in ipairs(result.options) do
    if option.kind == "lines" then found[#found + 1] = option end
  end
  return found
end

-- Path length and time
load(baseWorld())
local meters, seconds = route_compare.pathLengthAndTime({ { edge(2), true }, { edge(3), true } })
check("path: lengths add up", near(meters, 500))
check("path: the lower of speed limit and curve limit counts", near(seconds, 300 / 15 + 200 / 25))
meters, seconds = route_compare.pathLengthAndTime({ { edge(99), true } })
check("path: an unknown edge counts nothing", near(meters, 0) and near(seconds, 0))

-- An edge whose curve speed limit the game does not hand to Lua
local REFUSED_EDGE, CONSTRUCTION = 4, 700
local function refusedWorld()
  local w = baseWorld({ SIM_PERSON = { lastMoveMode = WALK, walkSpeed = 1.5 } })
  w[NETWORK].TRANSPORT_NETWORK.edges[REFUSED_EDGE + 1] = setmetatable({ geometry = { length = 120 }, speedLimit = 12 }, {
    __index = function(_, key)
      if key == "curveSpeedLimit" then error("The native floating point can't fit inside a lua number") end
      return nil
    end,
  })
  return w
end
load(refusedWorld())
meters, seconds = route_compare.pathLengthAndTime({ { edge(REFUSED_EDGE), true } })
check("refused curve limit: the edge counts with its speed limit", near(meters, 120) and near(seconds, 120 / 12))

local function refusedLogLines(w, wire)
  load(w, function(api)
    api.engine.util.pathfinding.findPathNodeToNode = function() return { { edge(REFUSED_EDGE), true } } end
    if wire then wire(api) end
  end)
  local lines = {}
  local realPrint = print
  print = function(text) if tostring(text):find("curve speed limit", 1, true) then lines[#lines + 1] = text end end
  local ok, result = pcall(route_compare.compare, PERSON, trip())
  print = realPrint
  return lines, ok and result or nil
end

local refusedLines, refusedResult = refusedLogLines(refusedWorld())
check("refused curve limit: the options are computed", refusedResult ~= nil and kind(refusedResult, "car") ~= nil
  and near(kind(refusedResult, "car").seconds, 120 / 12))
check("refused curve limit: one log line names the edge", #refusedLines == 1
  and refusedLines[1]:find("edge " .. REFUSED_EDGE .. " of entity " .. NETWORK .. " (owner unknown)", 1, true) ~= nil, refusedLines[1])

local ownedByConstruction = refusedWorld()
ownedByConstruction[NETWORK].CONSTRUCTION = { fileName = "::/placeholders/generic.con" }
refusedLines = refusedLogLines(ownedByConstruction)
check("refused curve limit: the log names the construction of the edge",
  #refusedLines == 1 and refusedLines[1]:find("(construction ::/placeholders/generic.con)", 1, true) ~= nil, refusedLines[1])

local ownedByStreet = refusedWorld()
ownedByStreet[NETWORK].BASE_EDGE = { roadTemplate = "::/street.lua" }
ownedByStreet[CONSTRUCTION] = { CONSTRUCTION = { fileName = "::/station.con" } }
refusedLines = refusedLogLines(ownedByStreet, function(api)
  api.engine.system.streetConnectorSystem.getConstructionEntityForEdge = function(entity)
    return entity == NETWORK and CONSTRUCTION or -1
  end
end)
check("refused curve limit: the log names the street and its construction",
  #refusedLines == 1 and refusedLines[1]:find("(street or track ::/street.lua, construction ::/station.con)", 1, true) ~= nil, refusedLines[1])

load(baseWorld())
local quietLines = {}
do
  local realPrint = print
  print = function(text) if tostring(text):find("curve speed limit", 1, true) then quietLines[#quietLines + 1] = text end end
  route_compare.compare(PERSON, trip())
  print = realPrint
end
check("refused curve limit: no log line when every limit is readable", #quietLines == 0)
load(baseWorld())

-- The options of a person whose leg the game does not expose: every option is an estimate
local c = route_compare.compare(PERSON, trip())
check("options: from the shortest to the longest: car 28 s, walk 100 s, lines 680 s", #c.options == 3 and c.options[1].kind == "car"
  and c.options[2].kind == "walk" and c.options[3].kind == "lines" and c.error == nil and c.chosen == LINES)
check("options: the big maps of the engine are fetched once", mapCalls == 1 and catchableCalls == 3, tostring(mapCalls) .. " " .. tostring(catchableCalls))
local walk, car, lines = kind(c, "walk"), kind(c, "car"), kind(c, "lines")
check("walk: 150 m in 100 s, one leg with its edges", walk.available and near(walk.meters, 150) and near(walk.seconds, 100) and #walk.legs == 1
  and #walk.legs[1].edges == 2 and not walk.chosen)
check("car: 500 m with speed limits, one car leg", car.available and near(car.meters, 500) and near(car.seconds, 28) and car.legs[1].car == true
  and not car.chosen)
check("walk: runs between the person nodes of the streets of both buildings", pathCalls[1].mode == PERSON_MODE and #pathCalls[1].from == 2
  and pathCalls[1].from[1].entity == STREET_O and pathCalls[1].from[2].index == 1 and pathCalls[1].to[1].entity == STREET_T)
check("car: runs between the car nodes of the streets", pathCalls[2].mode == CAR_MODE and pathCalls[2].from[1].entity == STREET_O
  and pathCalls[2].from[1].index == 2 and pathCalls[2].to[2].index == 3)
check("lines: a walk to the first station, the ride, and a walk from the last station", #lines.legs == 3 and lines.legs[1].line == nil
  and lines.legs[2].line == LINE_SHARED and lines.legs[3].line == nil)
check("lines: the first walk leads from the origin building to the station", lines.legs[1].fromBuilding == ORIGIN and lines.legs[1].toStation == STATION_O
  and near(lines.legs[1].seconds, 100) and near(lines.legs[1].meters, 150))
check("lines: the ride with its stops, its time, its wait", lines.legs[2].fromStation == STATION_O and lines.legs[2].toStation == STATION_T
  and lines.legs[2].fromStopIndex == 0 and lines.legs[2].toStopIndex == 2 and near(lines.legs[2].seconds, 180) and near(lines.legs[2].waitSeconds, 300))
check("lines: the ride has its edges from stop to stop and its length", #lines.legs[2].edges == 2 and near(lines.legs[2].meters, 600))
check("lines: the last walk leads from the station to the target building", lines.legs[3].fromStation == STATION_T and lines.legs[3].toBuilding == TARGET)
check("lines: the totals hold the wait, the ride, and both walks", near(lines.seconds, 300 + 180 + 100 + 100) and near(lines.meters, 150 + 600 + 150))
check("lines: the minutes of the walks, the ride, and the wait add up to the minutes of the option", lines.minutes == 11 and lines.legs[1].minutes == 2
  and lines.legs[2].minutes == 3 and lines.legs[2].waitMinutes == 5 and lines.legs[3].minutes == 1 and lines.legs[1].waitMinutes == nil)
check("lines: the best route is marked when the game chose lines and exposes no leg", lines.chosen == true and not lines.legs[2].current)

-- The game chose the walk and the person walks: the option is the path of the game
load(baseWorld({
  SIM_PERSON = { lastMoveMode = WALK, walkSpeed = 2 },
  MODEL_PERSON = { path = { edges = { { range = { edgeId = edge(0), dir = true } }, { range = { edgeId = edge(1), dir = true } } } } },
}))
c = route_compare.compare(PERSON, trip({ phase = "walking" }))
walk = kind(c, "walk")
check("chosen walk: the leg is the path the person walks, and it is the current leg", walk.chosen and walk.legs[1].current == true and #walk.legs[1].edges == 2
  and near(walk.meters, 150) and near(walk.seconds, 75))
check("chosen walk: the pathfinder is asked for the car only, and for the walks to and from stations", calls(CAR_MODE) == 1 and not kind(c, "car").chosen)

-- The game chose the car and the person drives
load(baseWorld({
  SIM_PERSON = { lastMoveMode = DRIVE, walkSpeed = 1.5 },
  LAND_VEHICLE = {},
  MOVE_PATH = { path = { edges = { { edgeId = edge(2), dir = true }, { edgeId = edge(3), dir = true }, { edgeId = edge(0), dir = true } } } },
}))
c = route_compare.compare(PERSON, trip({ phase = "driving" }))
car = kind(c, "car")
check("chosen car: the leg is the path the person drives", car.chosen and car.legs[1].current == true and #car.legs[1].edges == 3 and near(car.meters, 600)
  and near(car.seconds, 28 + 10))
check("chosen car: the pathfinder is not asked for a drive", calls(CAR_MODE) == 0)
check("chosen car: the walk stays an estimate", kind(c, "walk").available and not kind(c, "walk").chosen and kind(c, "walk").legs[1].current == nil)

-- The game chose lines and the person waits for the line: the leg of the game, with the estimate before and after it
load(baseWorld())
c = route_compare.compare(PERSON, trip({ phase = "waiting", line = LINE_SHARED, boardStation = STATION_O, leaveStation = STATION_T, boardStopIndex = 0,
  leaveStopIndex = 2 }))
local options = linesOptions(c)
check("waiting: the route of the person takes the place of the estimate with the same lines", #options == 1 and options[1].chosen)
local legs = options[1].legs
check("waiting: the walk to the stop, the ride, the walk to the target", #legs == 3 and legs[1].fromBuilding == ORIGIN and legs[1].toStation == STATION_O
  and legs[2].line == LINE_SHARED and legs[3].toBuilding == TARGET)
check("waiting: the ride is the current leg, the walks are not", legs[2].current == true and not legs[1].current and not legs[3].current)
check("waiting: the ride of the person has the average wait, and the total holds it", near(legs[2].waitSeconds, 300)
  and near(options[1].seconds, 100 + 300 + 180 + 100))
check("waiting: 100 s, 180 s, 300 s, 100 s are 2, 3, 5, and 1 of 11 minutes", options[1].minutes == 11 and legs[1].minutes == 2
  and legs[2].minutes == 3 and legs[2].waitMinutes == 5 and legs[3].minutes == 1)

-- The person leaves the line before the target: the rest of the trip is the estimate from that station
c = route_compare.compare(PERSON, trip({ phase = "riding", line = LINE_SHARED, boardStation = STATION_O, leaveStation = STATION_FAR, boardStopIndex = 0,
  leaveStopIndex = 1 }))
options = linesOptions(c)
local actual
for _, option in ipairs(options) do
  if option.chosen then actual = option end
end
check("riding: the route of the person and the estimate with other legs are two options", #options == 2 and actual ~= nil)
check("riding: the ride of the game, then the estimated ride from the leave station, then the walk", #actual.legs == 4 and actual.legs[2].current == true
  and actual.legs[2].toStation == STATION_FAR and near(actual.legs[2].seconds, 60) and actual.legs[3].fromStation == STATION_FAR
  and not actual.legs[3].current and actual.legs[4].toBuilding == TARGET)

-- The person walks to the stop of a line: the walk of the game takes the place of the estimated walk
load(baseWorld({
  SIM_PERSON = { lastMoveMode = LINES, walkSpeed = 1.5 },
  MODEL_PERSON = { path = { edges = { { range = { edgeId = edge(0), dir = true } } } } },
}))
c = route_compare.compare(PERSON, trip({ phase = "walking", line = LINE_SHARED, boardStation = STATION_O, leaveStation = STATION_T, boardStopIndex = 0,
  leaveStopIndex = 2 }))
legs = linesOptions(c)[1].legs
check("walking to a stop: the walk of the game, the ride, the walk to the target", #legs == 3 and #legs[1].edges == 1 and near(legs[1].meters, 100)
  and legs[1].toStation == STATION_O and legs[2].line == LINE_SHARED)
check("walking to a stop: the walk is the current leg, the ride is not", legs[1].current == true and not legs[2].current)

-- The person walks with no line ahead: the walk after the last ride
c = route_compare.compare(PERSON, trip({ phase = "walking" }))
options = linesOptions(c)
legs = options[1].legs
check("last walk: the estimated walk and ride, then the walk of the game to the target", #options == 1 and options[1].chosen and #legs == 3
  and legs[1].fromBuilding == ORIGIN and legs[2].line == LINE_SHARED and legs[3].current == true and legs[3].toBuilding == TARGET and #legs[3].edges == 1)

-- Three lines between the same stations. With the wait and the walks: 680 s, 500 s + the ride of the second, and 1200 s
local LINE_B, LINE_C = 41, 42
local VEHICLE_B, VEHICLE_C = 51, 52
local function threeLines(secondRide)
  local w = baseWorld()
  w[LINE_B], w[LINE_C] = w[LINE_SHARED], w[LINE_SHARED]
  w[VEHICLE_B] = { TRANSPORT_VEHICLE = { sectionTimes = { secondRide - 120, 120, 180 } } }
  w[VEHICLE_C] = { TRANSPORT_VEHICLE = { sectionTimes = { 580, 120, 180 } } }
  load(w, function(api)
    local stops = { [STATION_O] = 0, [STATION_FAR] = 1, [STATION_T] = 2 }
    local vehicles = { [LINE_SHARED] = VEHICLE, [LINE_B] = VEHICLE_B, [LINE_C] = VEHICLE_C }
    api.engine.system.lineSystem.getLineStopsForStation = function(stationEntity)
      local stop = stops[stationEntity]
      return stop and { { LINE_SHARED, stop }, { LINE_B, stop }, { LINE_C, stop } } or {}
    end
    api.engine.system.transportVehicleSystem.getLineVehicles = function(line) return { vehicles[line] } end
  end)
end

threeLines(210)
options = linesOptions(route_compare.compare(PERSON, trip()))
check("shortlist: the shortest route and the second within 10 % of it, not the third", #options == 2 and near(options[1].seconds, 680)
  and near(options[2].seconds, 710) and options[1].chosen and not options[2].chosen)

threeLines(280)
options = linesOptions(route_compare.compare(PERSON, trip()))
check("shortlist: a second route more than 10 % longer is left out", #options == 1 and near(options[1].seconds, 680))

threeLines(210)
options = linesOptions(route_compare.compare(PERSON, trip({ phase = "waiting", line = LINE_C, boardStation = STATION_O, leaveStation = STATION_T,
  boardStopIndex = 0, leaveStopIndex = 2 })))
check("shortlist: the route the game chose stays, also as the third", #options == 3 and near(options[3].seconds, 100 + 300 + 700 + 100) and options[3].chosen
  and not options[1].chosen)

-- The line ends one station before the target: the walk between the two stations and the walk to the building are one leg
local function walkWorld()
  local w = baseWorld()
  w[LINE_SHARED].LINE.stops = { { stationGroup = GROUP, station = 0, terminal = 0 }, { stationGroup = GROUP, station = 1, terminal = 0 } }
  return w
end
local function wireWalk(failingPersonCalls)
  return function(api)
    api.engine.system.lineSystem.getLineStopsForStation = function(stationEntity)
      if stationEntity == STATION_O then return { { LINE_SHARED, 0 } } end
      if stationEntity == STATION_FAR then return { { LINE_SHARED, 1 } } end
      return {}
    end
    api.engine.system.catchmentAreaSystem.getStation2stationsAndDistancesMap = function()
      return { [STATION_FAR] = { [STATION_T] = 300 }, [STATION_T] = { [STATION_FAR] = 300 } }
    end
    local find = api.engine.util.pathfinding.findPathNodeToNode
    local personCalls = 0
    api.engine.util.pathfinding.findPathNodeToNode = function(fromNodes, toNodes, modes)
      if modes[1] == PERSON_MODE then
        personCalls = personCalls + 1
        if failingPersonCalls[personCalls] then return {} end
      end
      return find(fromNodes, toNodes, modes)
    end
  end
end

load(walkWorld(), wireWalk({}))
lines = kind(route_compare.compare(PERSON, trip()), "lines")
check("joined walk: the walk between two stations and the walk to the building are one leg", #lines.legs == 3 and lines.legs[2].line == LINE_SHARED
  and lines.legs[3].fromStation == STATION_FAR and lines.legs[3].toBuilding == TARGET and lines.legs[3].toStation == nil)
check("joined walk: its path is the path between its two ends", #lines.legs[3].edges == 2 and near(lines.legs[3].meters, 150)
  and near(lines.legs[3].seconds, 100) and near(lines.seconds, 100 + 300 + 60 + 100))

-- The calls for a walk: the walk option, then both directions of the walk to the first station, of the joined walk, and of
-- each of its two parts
load(walkWorld(), wireWalk({ [4] = true, [5] = true }))
lines = kind(route_compare.compare(PERSON, trip()), "lines")
check("joined walk: without a path between its ends it is the sum of its parts", #lines.legs == 3 and #lines.legs[3].edges == 4
  and near(lines.legs[3].meters, 300) and near(lines.legs[3].seconds, 200) and lines.legs[3].fromStation == STATION_FAR
  and lines.legs[3].toBuilding == TARGET)

-- Two options with the same shown time: the choice of the game comes first
load(baseWorld({ SIM_PERSON = { lastMoveMode = WALK, walkSpeed = 5.3 } }))
c = route_compare.compare(PERSON, trip())
check("same time: a chosen walk of 28.3 s comes before a drive of 28 s", c.options[1].kind == "walk" and c.options[1].chosen
  and c.options[2].kind == "car" and near(c.options[2].seconds, 28))
load(baseWorld({ SIM_PERSON = { lastMoveMode = DRIVE, walkSpeed = 5.3 } }))
c = route_compare.compare(PERSON, trip())
check("same time: a chosen drive stays before the walk", c.options[1].kind == "car" and c.options[1].chosen and c.options[2].kind == "walk")

threeLines(185)
options = linesOptions(route_compare.compare(PERSON, trip({ phase = "waiting", line = LINE_B, boardStation = STATION_O, leaveStation = STATION_T,
  boardStopIndex = 0, leaveStopIndex = 2 })))
check("same time: the chosen route of 685 s comes before the route of 680 s, both 11 minutes", #options == 2 and options[1].chosen
  and near(options[1].seconds, 685) and near(options[2].seconds, 680) and options[1].minutes == 11 and options[2].minutes == 11)

-- Errors
load(baseWorld())
c = route_compare.compare(777, trip())
check("compare: unknown person", c.error == "prc_note_no_person" and #c.options == 0)
c = route_compare.compare(PERSON, nil)
check("compare: no state", c.error == "prc_note_no_person")
c = route_compare.compare(PERSON, trip({ targetEntity = ORIGIN }))
check("compare: same origin and target", c.error == "prc_note_no_trip" and c.chosen == LINES)
c = route_compare.compare(PERSON, trip({ originEntity = -1 }))
check("compare: missing origin", c.error == "prc_note_no_trip")

-- The pathfinder fails or finds nothing
load(baseWorld(), function(api)
  api.engine.util.pathfinding.findPathNodeToNode = function(fromNodes, toNodes, modes)
    if modes[1] == PERSON_MODE then error("bad argument") end
    return {}
  end
end)
c = route_compare.compare(PERSON, trip())
check("pathfinder error: walk not available, with the message", kind(c, "walk").available == false and kind(c, "walk").note:find("bad argument", 1, true) ~= nil
  and kind(c, "walk").seconds == nil)
check("empty path: car not available", kind(c, "car").available == false and kind(c, "car").note == "prc_note_no_path")
check("options that are not available come last, walk before car", c.options[1].kind == "lines" and c.options[2].kind == "walk" and c.options[3].kind == "car")
lines = kind(c, "lines")
check("no paths: the route by lines keeps its ride, without walks, edges, and length", #lines.legs == 1 and lines.legs[1].edges == nil
  and near(lines.seconds, 480) and near(lines.meters, 0))

-- A building without parcels
local industryWorld = baseWorld()
industryWorld[ORIGIN] = {}
load(industryWorld)
c = route_compare.compare(PERSON, trip())
check("no parcels: walk and car have no start", kind(c, "walk").note == "prc_note_no_nodes" and kind(c, "car").note == "prc_note_no_nodes")
check("no parcels: the route by lines has no first walk", #kind(c, "lines").legs == 2 and kind(c, "lines").legs[1].line == LINE_SHARED)

-- No station in reach of the target, of the origin, and no route
load(baseWorld(), function(api)
  api.engine.system.catchmentAreaSystem.getStationCatchables = function(stationEntity)
    if stationEntity == STATION_O then return { ORIGIN } end
    return {}
  end
end)
c = route_compare.compare(PERSON, trip())
check("no target station: one lines option, not available, with the note, and the choice of the game", #c.options == 3 and kind(c, "lines").available == false
  and kind(c, "lines").note == "prc_note_no_station" and kind(c, "lines").chosen == true)

load(baseWorld(), function(api)
  api.engine.system.catchmentAreaSystem.getStationCatchables = function(stationEntity)
    if stationEntity == STATION_T then return { TARGET } end
    return {}
  end
end)
c = route_compare.compare(PERSON, trip())
check("no origin station: note", kind(c, "lines").available == false and kind(c, "lines").note == "prc_note_no_station")

load(baseWorld(), function(api)
  api.engine.system.transportVehicleSystem.getLineVehicles = function() return {} end
end)
c = route_compare.compare(PERSON, trip())
check("no route: note", kind(c, "lines").available == false and kind(c, "lines").note == "prc_note_no_shared_line")

support.finish("route_compare")
