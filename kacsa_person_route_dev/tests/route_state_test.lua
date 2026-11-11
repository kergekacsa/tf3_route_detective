-- Tests of route_state.tl: the plain data the Route card shows for each phase of a trip.

local support = dofile((arg[0]:match("^(.*)[/\\][^/\\]*$") or ".") .. "/support.lua")
local check, near = support.check, support.near

support.installRequire()

local HOME, SHOP, WORK = 10, 11, 12
local PERSON = 100
local LINE, GROUP, STATION_A, STATION_B, VEHICLE = 200, 300, 301, 302, 400
local NOW = 1000 * 1000 -- 1000 s of game time in milliseconds

local function world(personComponents, extra)
  local w = {
    [support.WORLD] = { GAME_TIME = { gameTime = NOW } },
    [PERSON] = personComponents,
    [LINE] = { LINE = { stops = {
      { stationGroup = GROUP, station = 0 },
      { stationGroup = GROUP, station = 1 },
      { stationGroup = 999, station = 0 },
    } } },
    [GROUP] = { STATION_GROUP = { stations = { STATION_A, STATION_B } } },
  }
  for entity, components in pairs(extra or {}) do w[entity] = components end
  return w
end

local function simPerson(fields)
  local sp = {
    destinations = { HOME, SHOP, WORK },
    moveModes = { 0, 2, 1 },
    travelTimes = { 60, 600, 900 },
    targetOrAtEntity = WORK,
    lastNonResType = 2,
    lastMoveMode = 2,
    walkSpeed = 1.5,
    lastDestinationUpdate = NOW - 30 * 1000,
    happiness = 0.8,
  }
  for k, v in pairs(fields or {}) do sp[k] = v end
  return sp
end

local route_state

local function load(w)
  support.installApi(w)
  route_state = ug_require("kacsa_person_route::/person_route/route_state.tl")
end

-- Gone entity
load(world({ SIM_PERSON = simPerson() }))
check("gone entity gives nil", route_state.read(555) == nil)
check("entity without SimPerson gives nil", route_state.read(LINE) == nil)
check("destinationIndex finds home, shop, work", route_state.destinationIndex({ HOME, SHOP, WORK }, HOME) == 0
  and route_state.destinationIndex({ HOME, SHOP, WORK }, SHOP) == 1 and route_state.destinationIndex({ HOME, SHOP, WORK }, WORK) == 2)
check("destinationIndex gives -1 for a stranger and for -1", route_state.destinationIndex({ HOME, SHOP, WORK }, 77) == -1
  and route_state.destinationIndex({ HOME, SHOP, WORK }, -1) == -1)

-- At home
load(world({ SIM_PERSON = simPerson({ targetOrAtEntity = HOME }), SIM_ENTITY_AT_BUILDING = {} }))
local s = route_state.read(PERSON)
check("at building: phase", s.phase == "building")
check("at building: origin and target are the building", s.originIndex == 0 and s.targetIndex == 0 and s.originEntity == HOME and s.targetEntity == HOME)
check("at building: no line and no leg data", s.line == nil and s.waitingSeconds == nil)
check("at building: happiness", near(s.happiness, 0.8))

-- Waiting at a terminal, 90 s so far, vehicle known
load(world({
  SIM_PERSON = simPerson(),
  SIM_ENTITY_AT_TERMINAL = { line = LINE, lineStop0 = 0, lineStop1 = 1, arrivalTime = NOW - 90 * 1000, vehicle = VEHICLE },
}))
s = route_state.read(PERSON)
check("waiting: phase and move mode", s.phase == "waiting" and s.moveMode == 2)
check("waiting: origin home, target work", s.originIndex == 0 and s.targetIndex == 2 and s.originEntity == HOME and s.targetEntity == WORK)
check("waiting: line and stops", s.line == LINE and s.boardStopIndex == 0 and s.leaveStopIndex == 1)
check("waiting: stations resolved through the station group", s.boardStation == STATION_A and s.leaveStation == STATION_B)
check("waiting: 90 s is not late", near(s.waitingSeconds, 90) and s.waitingLate == false)
check("waiting: vehicle", s.waitingVehicle == VEHICLE)

-- Waiting 130 s, no vehicle yet, stop whose group is unknown
load(world({
  SIM_PERSON = simPerson(),
  SIM_ENTITY_AT_TERMINAL = { line = LINE, lineStop0 = 2, lineStop1 = 0, arrivalTime = NOW - 130 * 1000, vehicle = -1 },
}))
s = route_state.read(PERSON)
check("waiting long: late", s.waitingLate == true)
check("waiting long: no vehicle", s.waitingVehicle == nil)
check("waiting long: unknown group falls back to the group entity", s.boardStation == 999 and s.leaveStation == STATION_A)

-- Riding
load(world({
  SIM_PERSON = simPerson(),
  SIM_ENTITY_AT_VEHICLE = { line = LINE, lineStop0 = 1, lineStop1 = 2, vehicle = VEHICLE },
  SIM_PERSON_AT_VEHICLE = { vehicle = VEHICLE, expectedArrivalTime = NOW + 45 * 1000 },
}))
s = route_state.read(PERSON)
check("riding: phase, line, stops", s.phase == "riding" and s.line == LINE and s.boardStopIndex == 1 and s.leaveStopIndex == 2)

-- Walking to the shop with a partial path
load(world({
  SIM_PERSON = simPerson({ targetOrAtEntity = SHOP, lastMoveMode = 0 }),
  MODEL_PERSON = {},
  SIM_ENTITY_MOVING = { line = -1, lineStop0 = -1, lineStop1 = -1, partialPath = false, expectedArrivalTime = NOW + 10 * 1000 },
}))
s = route_state.read(PERSON)
check("walking: phase", s.phase == "walking")
check("walking: origin home, target shop", s.originIndex == 0 and s.targetIndex == 1)
check("walking: no line from a moving component with line -1", s.line == nil)

-- Walking towards a line: the moving component names the line
load(world({
  SIM_PERSON = simPerson(),
  MODEL_PERSON = {},
  SIM_ENTITY_MOVING = { line = LINE, lineStop0 = 0, lineStop1 = 1, partialPath = true, expectedArrivalTime = -1 },
}))
s = route_state.read(PERSON)
check("walking to a stop: line and stations from the moving component", s.line == LINE and s.boardStation == STATION_A and s.leaveStation == STATION_B)

-- Driving home from work
load(world({
  SIM_PERSON = simPerson({ targetOrAtEntity = HOME, lastMoveMode = 1, lastNonResType = 2 }),
  LAND_VEHICLE = {},
  SIM_ENTITY_MOVING = { line = -1, lineStop0 = -1, lineStop1 = -1, partialPath = true, expectedArrivalTime = -1 },
}))
s = route_state.read(PERSON)
check("driving: phase", s.phase == "driving")
check("driving home: origin is the last non-residential destination", s.originIndex == 2 and s.originEntity == WORK and s.targetIndex == 0)

-- Driving detected through MOVE_PATH only
load(world({ SIM_PERSON = simPerson({ lastMoveMode = 1 }), MOVE_PATH = {} }))
s = route_state.read(PERSON)
check("move path alone counts as driving", s.phase == "driving")

-- Nothing known
load(world({ SIM_PERSON = simPerson({ targetOrAtEntity = 77 }) }))
s = route_state.read(PERSON)
check("no state component: phase unknown, target index -1", s.phase == "unknown" and s.targetIndex == -1 and s.originIndex == 0)

-- Towns of the origin and the target
local TOWN = 600
load(world({ SIM_PERSON = simPerson() }, {
  [HOME] = { TOWN_BUILDING = { town = TOWN } },
  [WORK] = { PERSON_CAPACITY = {} },
}))
s = route_state.read(PERSON)
check("towns: home has a town, the industry has none", s.originTown == TOWN and s.targetTown == nil)

-- Current path: a driving person follows the move path
local function edge(index) return { entity = 500, index = index } end
load(world({
  SIM_PERSON = simPerson({ lastMoveMode = 1 }),
  LAND_VEHICLE = {},
  MOVE_PATH = { path = { edges = { { edge(0), true }, { edge(1), false } } } },
}))
local path = route_state.currentPath(PERSON)
check("current path: the move path edges", #path == 2 and path[1][1].index == 0 and path[2][2] == false)

-- Current path: a walking person follows the ranges of the model path
load(world({
  SIM_PERSON = simPerson({ lastMoveMode = 0 }),
  MODEL_PERSON = { path = { edges = { { range = { edgeId = edge(3), dir = true } }, { link = {} }, { range = { edgeId = edge(4), dir = false } } } } },
}))
path = route_state.currentPath(PERSON)
check("current path: the edge ranges of the walk, links skipped", #path == 2 and path[1][1].index == 3 and path[1][2] == true and path[2][1].index == 4 and path[2][2] == false)

-- Current path: entries the engine hands out empty are skipped, and the result holds plain copies
local view = edge(7)
load(world({
  SIM_PERSON = simPerson({ lastMoveMode = 1 }),
  MOVE_PATH = { path = { edges = { { nil, true }, { view, true }, { { entity = 500 }, false } } } },
}))
path = route_state.currentPath(PERSON)
check("current path: unreadable edge ids are skipped", #path == 1 and path[1][1].index == 7)
check("current path: the edge id is a copy, not the engine's object", path[1][1] ~= view)

-- Current path: a person at a terminal or on a vehicle still carries the walking path of the leg before
load(world({
  SIM_PERSON = simPerson(),
  SIM_ENTITY_AT_TERMINAL = { line = LINE, lineStop0 = 0, lineStop1 = 1, arrivalTime = NOW, vehicle = -1 },
  MODEL_PERSON = { path = { edges = { { range = { edgeId = edge(3), dir = true } } } } },
}))
check("current path: empty while waiting, the old walking path is not used", #route_state.currentPath(PERSON) == 0)
load(world({
  SIM_PERSON = simPerson(),
  SIM_ENTITY_AT_VEHICLE = { line = LINE, lineStop0 = 0, lineStop1 = 1, vehicle = VEHICLE },
  MODEL_PERSON = { path = { edges = { { range = { edgeId = edge(3), dir = true } } } } },
}))
check("current path: empty while riding", #route_state.currentPath(PERSON) == 0)
check("stationOfStop: station of a stop, the group as fallback, nil for an unknown stop", route_state.stationOfStop(LINE, 1) == STATION_B
  and route_state.stationOfStop(LINE, 2) == 999 and route_state.stationOfStop(LINE, 9) == nil and route_state.stationOfStop(LINE, -1) == nil)

-- Current path: none at a building or for a gone entity
load(world({ SIM_PERSON = simPerson({ targetOrAtEntity = HOME }), SIM_ENTITY_AT_BUILDING = {} }))
check("current path: empty at a building", #route_state.currentPath(PERSON) == 0)
check("current path: empty for a gone entity", #route_state.currentPath(555) == 0)

support.finish("route_state")
