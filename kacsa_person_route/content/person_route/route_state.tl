-- Reads the trip of one person from the engine into plain data. The game keeps only the route it chose; this module reads
-- that route and nothing else. Every engine read of the Route card goes through here, so the recipe stays free of `api`.

local route_state : PrcRouteStateModule = {}

local MS_PER_SECOND <const> = 1000
-- The vanilla person window turns the happiness trend negative after this wait at a terminal (sim_person.tl).
local LATE_WAIT_SECONDS <const> = 120
local DESTINATION_COUNT <const> = 3

local function component<T>(entity : Engine.Entity, kind : Engine.ComponentType) : T
	if entity == nil or entity < 0 then
		return nil
	end
	return api.engine.getComponent(entity, kind) as T
end

local function gameTimeMs() : integer
	local gt = component(api.engine.util.getWorld(), api.type.ComponentType.GAME_TIME) as Engine.Component.GameTime
	return gt and gt.gameTime or 0
end

route_state.destinationIndex = function(destinations : {Engine.Entity}, entity : Engine.Entity) : integer
	if entity == nil or entity < 0 then
		return -1
	end
	for i = 1, DESTINATION_COUNT do
		if destinations[i] == entity then
			return i - 1
		end
	end
	return -1
end

-- The station entity of a line stop: the station of the stop inside its station group, or the group when the station
-- list does not hold it.
route_state.stationOfStop = function(line : Engine.Entity, stopIndex : integer) : Engine.Entity
	if stopIndex == nil or stopIndex < 0 then
		return nil
	end
	local lineComp = component(line, api.type.ComponentType.LINE) as Engine.Component.Line
	if not lineComp or not lineComp.stops then
		return nil
	end
	local stop = lineComp.stops[stopIndex + 1]
	if not stop then
		return nil
	end
	local group = component(stop.stationGroup, api.type.ComponentType.STATION_GROUP) as Engine.Component.StationGroup
	if group and group.stations and group.stations[stop.station + 1] then
		return group.stations[stop.station + 1]
	end
	return stop.stationGroup
end

local function townOf(entity : Engine.Entity) : Engine.Entity
	local building = component(entity, api.type.ComponentType.TOWN_BUILDING) as Engine.Component.TownBuilding
	if building and building.town ~= nil and building.town >= 0 then
		return building.town
	end
	return nil
end

route_state.edgeOf = function(entry : any) : {EdgeId, boolean}
	if entry == nil then
		return nil
	end
	local edgeId : EdgeId
	local dir : boolean
	pcall(function()
		local pair = entry as {any}
		edgeId = pair[1] as EdgeId
		dir = pair[2] as boolean
	end)
	if edgeId == nil then
		pcall(function()
			local named = entry as {string : any}
			edgeId = named["edgeId"] as EdgeId
			dir = named["dir"] as boolean
		end)
	end
	if edgeId == nil then
		return nil
	end
	local entity : Engine.Entity
	local index : integer
	pcall(function()
		entity = edgeId.entity
		index = edgeId.index
	end)
	if entity == nil or index == nil then
		return nil
	end
	return { { entity = entity, index = index } as EdgeId, dir == true }
end

local LOG_PREFIX <const> = "[PersonRoute] "
-- The log line about an unreadable walking path is written once per game session.
local unreadableLogged = false

route_state.currentPath = function(personEntity : Engine.Entity) : {{EdgeId, boolean}}
	local edges : {{EdgeId, boolean}} = {}
	if personEntity == nil or personEntity < 0 or not api.engine.entityExists(personEntity) then
		return edges
	end
	-- A person at a building, at a terminal, or on a vehicle keeps the walking path of the leg before.
	local kinds = api.type.ComponentType
	if component(personEntity, kinds.SIM_ENTITY_AT_BUILDING) ~= nil or component(personEntity, kinds.SIM_ENTITY_AT_TERMINAL) ~= nil
		or component(personEntity, kinds.SIM_ENTITY_AT_VEHICLE) ~= nil then
		return edges
	end
	local movePath = component(personEntity, api.type.ComponentType.MOVE_PATH) as Engine.Component.MovePath
	if movePath and movePath.path and movePath.path.edges then
		for i = 1, #movePath.path.edges do
			edges[#edges + 1] = route_state.edgeOf(movePath.path.edges[i])
		end
		return edges
	end
	local modelPerson = component(personEntity, api.type.ComponentType.MODEL_PERSON) as Engine.Component.ModelPerson
	if modelPerson and modelPerson.path and modelPerson.path.edges then
		local entries = #modelPerson.path.edges
		for i = 1, entries do
			local pathEdge = modelPerson.path.edges[i]
			local range = pathEdge and pathEdge.range
			edges[#edges + 1] = route_state.edgeOf(range)
		end
		if entries > 0 and #edges == 0 and not unreadableLogged then
			unreadableLogged = true
			print(LOG_PREFIX .. "walking path of person " .. tostring(personEntity) .. " has " .. tostring(entries) .. " entries, none readable")
		end
	end
	return edges
end

route_state.read = function(personEntity : Engine.Entity) : PrcRouteState
	if personEntity == nil or personEntity < 0 or not api.engine.entityExists(personEntity) then
		return nil
	end
	local simPerson = component(personEntity, api.type.ComponentType.SIM_PERSON) as Engine.Component.SimPerson
	if not simPerson then
		return nil
	end
	local now = gameTimeMs()

	local state : PrcRouteState = {
		phase = "unknown",
		moveMode = simPerson.lastMoveMode,
		targetIndex = route_state.destinationIndex(simPerson.destinations, simPerson.targetOrAtEntity),
		targetEntity = simPerson.targetOrAtEntity,
		happiness = simPerson.happiness,
	}
	-- The vanilla window shows the home as origin of every trip that does not end at home, and the last non-residential
	-- destination as origin of a trip home.
	if state.targetIndex == 0 then
		state.originIndex = simPerson.lastNonResType as integer
	else
		state.originIndex = 0
	end
	state.originEntity = simPerson.destinations[state.originIndex + 1]
	state.originTown = townOf(state.originEntity)
	state.targetTown = townOf(state.targetEntity)

	local atBuilding = component(personEntity, api.type.ComponentType.SIM_ENTITY_AT_BUILDING) as Engine.Component.SimEntityAtBuilding
	local atTerminal = component(personEntity, api.type.ComponentType.SIM_ENTITY_AT_TERMINAL) as Engine.Component.SimEntityAtTerminal
	local atVehicle = component(personEntity, api.type.ComponentType.SIM_ENTITY_AT_VEHICLE) as Engine.Component.SimEntityAtVehicle
	local moving = component(personEntity, api.type.ComponentType.SIM_ENTITY_MOVING) as Engine.Component.SimEntityMoving

	if atBuilding then
		state.phase = "building"
		state.originIndex = state.targetIndex
		state.originEntity = state.targetEntity
	elseif atTerminal then
		state.phase = "waiting"
		state.line = atTerminal.line
		state.boardStopIndex = atTerminal.lineStop0
		state.leaveStopIndex = atTerminal.lineStop1
		state.waitingSeconds = (now - atTerminal.arrivalTime) / MS_PER_SECOND
		state.waitingLate = state.waitingSeconds > LATE_WAIT_SECONDS
		if atTerminal.vehicle ~= nil and atTerminal.vehicle >= 0 then
			state.waitingVehicle = atTerminal.vehicle
		end
	elseif atVehicle then
		state.phase = "riding"
		state.line = atVehicle.line
		state.boardStopIndex = atVehicle.lineStop0
		state.leaveStopIndex = atVehicle.lineStop1
	else
		local inCar = component(personEntity, api.type.ComponentType.LAND_VEHICLE) ~= nil
			or component(personEntity, api.type.ComponentType.MOVE_PATH) ~= nil
		if inCar then
			state.phase = "driving"
		elseif component(personEntity, api.type.ComponentType.MODEL_PERSON) ~= nil then
			state.phase = "walking"
		end
	end

	if moving then
		if moving.line ~= nil and moving.line >= 0 and state.line == nil then
			state.line = moving.line
			state.boardStopIndex = moving.lineStop0
			state.leaveStopIndex = moving.lineStop1
		end
	end

	if state.line ~= nil and state.line < 0 then
		state.line = nil
	end
	if state.line ~= nil then
		state.boardStation = route_state.stationOfStop(state.line, state.boardStopIndex)
		state.leaveStation = route_state.stationOfStop(state.line, state.leaveStopIndex)
	end

	return state
end

return route_state
