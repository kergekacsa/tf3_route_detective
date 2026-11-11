-- Types of the Route card modules. Every global name carries the prefix Prc, because global names are shared by all loaded mods.

--- Plain data about the current trip of one person. Every field is a number, a string, a boolean, or an entity id, so a deep
--- comparison of two states is cheap and the card re-renders only on a change.
global record PrcRouteState
	--- "building", "waiting", "riding", "walking", "driving", or "unknown"
	phase : string
	--- `SimPerson.lastMoveMode`
	moveMode : MoveMode
	--- 0 home, 1 shop, 2 work, -1 unknown
	originIndex : integer
	targetIndex : integer
	originEntity : Engine.Entity
	targetEntity : Engine.Entity
	--- the towns of the two buildings, nil for an industry
	originTown : Engine.Entity
	targetTown : Engine.Entity
	--- the line of the current leg, nil when the leg uses no line
	line : Engine.Entity
	boardStopIndex : integer
	leaveStopIndex : integer
	--- station entities of the two stops, nil when unknown
	boardStation : Engine.Entity
	leaveStation : Engine.Entity
	--- seconds at the terminal so far, nil unless waiting
	waitingSeconds : number
	--- true when the wait passed the two minutes after which the vanilla window turns the happiness trend negative
	waitingLate : boolean
	--- the vehicle the person waits for, nil when none
	waitingVehicle : Engine.Entity
	happiness : number
end

--- Module: ug_require "kacsa_person_route::/person_route/route_state.tl" as PrcRouteStateModule
global record PrcRouteStateModule
	--- Reads the components of the person. Returns nil when the entity is gone or has no SimPerson component.
	read : function(personEntity : Engine.Entity) : PrcRouteState
	--- The destination index (0 home, 1 shop, 2 work) of an entity in `destinations`, or -1.
	destinationIndex : function(destinations : {Engine.Entity}, entity : Engine.Entity) : integer
	--- The edges of the path the person follows now: the car path while driving, the walking path while walking. Empty otherwise.
	currentPath : function(personEntity : Engine.Entity) : {{EdgeId, boolean}}
	--- The station entity of a line stop: the station of the stop inside its station group, or the group when the station
	--- list does not hold it. nil when the line or the stop is unknown.
	stationOfStop : function(line : Engine.Entity, stopIndex : integer) : Engine.Entity
	--- A plain Lua copy of one path entry of the engine, or nil when it is not readable. An entry is a pair of an edge id
	--- and a direction, or an object with the fields `edgeId` and `dir`. The engine hands out views of its data, and a
	--- view kept across steps can read empty.
	edgeOf : function(entry : any) : {EdgeId, boolean}
end

--- One leg of a route by lines: a ride on a line, a walk between two stations, or a walk between a building and a station.
global record PrcRouteLeg
	--- the line of the leg, nil for a walk
	line : Engine.Entity
	fromStation : Engine.Entity
	toStation : Engine.Entity
	--- the building a walk starts or ends at, in place of the station on that side
	fromBuilding : Engine.Entity
	toBuilding : Engine.Entity
	--- the edges the leg runs over, nil when the pathfinder gives none
	edges : {{EdgeId, boolean}}
	--- true for a drive; a leg without a line that is no drive is a walk
	car : boolean
	--- the length of the leg in metres, nil when not known
	meters : number
	--- true for the leg the person is on, or waits for
	current : boolean
	--- the stops of the line where the person boards and leaves, nil for a walk
	fromStopIndex : integer
	toStopIndex : integer
	--- seconds on the vehicle, from the section times of a vehicle of the line, or seconds on foot
	seconds : number
	--- half the interval between two vehicles of the line; nil for a walk and for a line without frequency
	waitSeconds : number
	--- `seconds` and `waitSeconds` in whole minutes, rounded so that the legs of an option add up to its `minutes`;
	--- set on the legs of an option, nil where the seconds are nil
	minutes : integer
	waitMinutes : integer
end

--- One route by lines: its legs in order, and the sum of their rides, waits, and walks.
global record PrcLineEstimate
	legs : {PrcRouteLeg}
	totalSeconds : number
end

--- The routes by lines to one set of target stations.
global record PrcLineSearch
	--- The best route from a station to a target station. Its legs are empty when the station is a target. nil when no
	--- route exists.
	routeFrom : function(station : Engine.Entity) : PrcLineEstimate
	--- For each line a person can board at the origin stations, or at a station in walking reach of them, the best route
	--- that starts with that line. Shortest total first, at most `maxOptions`.
	options : function(originStations : {Engine.Entity}, maxOptions : integer) : {PrcLineEstimate}
end

--- Module: ug_require "kacsa_person_route::/person_route/route_lines.tl" as PrcRouteLinesModule
global record PrcRouteLinesModule
	--- Builds the network of lines and walks between stations, and finds the best route from every station to the
	--- nearest of the target stations.
	search : function(targetStations : {Engine.Entity}, walkSpeed : number) : PrcLineSearch
	--- Runs a function that asks for routes, paths, and stations many times. The data of the engine that these calls share
	--- is fetched once for the whole function.
	batch : function(fn : function())
	--- The stations whose catchment area holds one of the entities.
	stationsInReach : function(entities : {Engine.Entity}) : {Engine.Entity}
	--- The seconds a vehicle needs from one stop of a line to another, from its section times. nil when the line has no vehicle.
	rideSeconds : function(line : Engine.Entity, fromStop : integer, toStop : integer) : number
	--- The average wait for a vehicle of a line in seconds: half the interval between two vehicles. nil when the line has no
	--- frequency.
	waitSeconds : function(line : Engine.Entity) : number
	--- A path of the game's pathfinder between two sets of nodes, as plain copies of its edges. nil and a note when the
	--- pathfinder gives none: a text key of the mod, or the message of the failed call.
	findPath : function(fromNodes : {NodeId}, toNodes : {NodeId}, modes : {TransportMode}) : {{EdgeId, boolean}}, string
	--- The edges a leg runs over: for a ride the path of the game's pathfinder from stop to stop between the nodes where
	--- the vehicles of the line stop, for a walk the path on foot between its two ends. nil when the pathfinder gives no
	--- path for a part of it.
	legPath : function(leg : PrcRouteLeg) : {{EdgeId, boolean}}
	--- The nodes of the street edges next to a town building that allow a transport mode: the streets of its parcels.
	--- Empty for an entity without parcels.
	buildingNodes : function(entity : Engine.Entity, mode : TransportMode) : {NodeId}
	--- The nodes of the street edge for persons that is nearest to a station, from its catchment area.
	stationNodes : function(station : Engine.Entity) : {NodeId}
end

--- One path drawn on the map: `edges` in a colour, or a whole `line` when the edges of a ride are not known.
global record PrcMapPath
	key : string
	edges : {{EdgeId, boolean}}
	line : Engine.Entity
	--- RGBA
	color : {number}
end

--- The paths the card wants on the map for one person. The tool reads it each step and redraws when `version` changes.
global record PrcMapPaths
	version : integer
	paths : {PrcMapPath}
end

--- One way to make the trip: on foot, by car, or by one route by lines.
global record PrcOption
	--- "walk", "car", or "lines"
	kind : string
	--- true for the option the game took
	chosen : boolean
	available : boolean
	--- why the option is not available: a text key of the mod, or the message of a failed engine call
	note : string
	--- rides, waits, walks, or the drive together; nil when not available
	seconds : number
	--- `seconds` in whole minutes
	minutes : integer
	meters : number
	--- one leg for a walk or a drive, the legs of the route for lines
	legs : {PrcRouteLeg}
end

global record PrcCompareResult
	--- identifies the trip the result belongs to, so the card recomputes only when the trip changes
	tripKey : string
	originEntity : Engine.Entity
	targetEntity : Engine.Entity
	--- `SimPerson.lastMoveMode`, the mode the game picked for the current trip
	chosen : MoveMode
	--- from the shortest to the longest; an option that is not available comes last
	options : {PrcOption}
	--- set when the comparison could not start at all
	error : string
end

--- Module: ug_require "kacsa_person_route::/person_route/route_compare.tl" as PrcRouteCompareModule
global record PrcRouteCompareModule
	--- The options of the trip of a person. The option the game chose holds the route of the game as far as the game
	--- exposes it, and the mod's estimate for the rest. The other options are the mod's estimate.
	compare : function(personEntity : Engine.Entity, state : PrcRouteState) : PrcCompareResult
	--- Sum of the lengths of a path in metres, and the seconds a vehicle at the speed limit of each edge needs for it.
	pathLengthAndTime : function(edges : {{EdgeId, boolean}}) : number, number
end

--- Module: ug_require "kacsa_person_route::/person_route/route_card.script.tl" as PrcRouteCard
global record PrcRouteCard
	RouteCardPlugin : Recipe<SimPersonEow.SimPersonWidgetPluginParams>
end
