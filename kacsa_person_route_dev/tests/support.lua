-- Shared helpers of the tests: loading the Lua that `tl gen` made from the mod's Teal files, a stub of the game's `api`,
-- and a small check function. The tests prove the logic of the mod, not that the game accepts a call.

local support = {}

local here = (arg and arg[0] or ""):match("^(.*)[/\\][^/\\]*$") or "."
support.buildDir = here .. "/.build"

local loaded = {}

-- Installs the global `ug_require` of the game. Every module loads from the build folder.
function support.installRequire()
  loaded = {}
  _G.ug_require = function(path)
    local name = path:match("([%w_%.]+)%.tl$")
    assert(name, "unknown module path " .. tostring(path))
    if not loaded[name] then
      local chunk = assert(loadfile(support.buildDir .. "/" .. name .. ".lua"))
      loaded[name] = chunk()
    end
    return loaded[name]
  end
end

support.WORLD = 1

-- The component kinds the modules read. The stub uses the names as values.
local kinds = {
  "GAME_TIME", "SIM_PERSON", "SIM_ENTITY_AT_BUILDING", "SIM_ENTITY_AT_TERMINAL", "SIM_ENTITY_AT_VEHICLE",
  "SIM_ENTITY_MOVING", "SIM_PERSON_AT_VEHICLE", "LAND_VEHICLE", "MOVE_PATH", "MODEL_PERSON", "LINE", "STATION_GROUP",
  "TRANSPORT_NETWORK", "PERSON_CAPACITY", "TOWN_BUILDING", "TRANSPORT_VEHICLE", "STATION", "PARCEL", "BASE_EDGE", "TP_NET_LINK",
}

-- Installs the global `api` with a world of entities. `world[entity][kind]` is the component. The other fields of the
-- stub are empty; a test sets what it needs.
function support.installApi(world)
  local componentType = {}
  for _, kind in ipairs(kinds) do componentType[kind] = kind end
  _G.api = {
    type = {
      ComponentType = componentType,
      EdgeId = { new = function(entity, index) return { entity = entity, index = index } end },
      NodeId = { new = function(entity, index) return { entity = entity, index = index } end },
      enum = {
        MoveMode = { WALK = 0, DRIVE = 1, LINES = 2 },
        TransportMode = { PERSON = 0, CARGO = 1, CAR = 2, BUS = 3 },
      },
    },
    engine = {
      entityExists = function(entity) return world[entity] ~= nil end,
      getComponent = function(entity, kind)
        local components = world[entity]
        return components and components[kind] or nil
      end,
      util = {
        getWorld = function() return support.WORLD end,
        pathfinding = {},
        line = {},
      },
      system = {
        catchmentAreaSystem = {},
        lineSystem = {},
        transportVehicleSystem = {},
        tpNetLinkSystem = {},
      },
    },
  }
  return _G.api
end

local failures = 0
local count = 0

function support.check(name, condition, detail)
  count = count + 1
  if condition then
    print("ok   " .. name)
  else
    failures = failures + 1
    print("FAIL " .. name .. (detail and (": " .. tostring(detail)) or ""))
  end
end

function support.near(a, b)
  return type(a) == "number" and type(b) == "number" and math.abs(a - b) < 1e-6
end

-- Prints the result and ends the process with the matching exit code.
function support.finish(title)
  print(string.format("%s: %d checks, %d failed", title, count, failures))
  os.exit(failures == 0 and 0 or 1)
end

return support
