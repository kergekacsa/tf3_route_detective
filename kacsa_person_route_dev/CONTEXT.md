# Route Detective

A Transport Fever 3 mod (mod id `kacsa_person_route`) with one card in the person window. The card shows the trip the game chose for a person and the mod's estimate of the options.

## Language

**Block**:
One of the two parts of the expandable part of the card, with a thick divider between them: the trip, and Options.
_Avoid_: Section, panel

**Card**:
One part of the person window with a title, a permanent row, and an expandable part. The vanilla window has the cards Locations, Happiness, and Current Route. This mod adds Route.
_Avoid_: Tab, panel, widget

**Trip**:
The way from one destination of the person to another. A person has three destinations: home, shop, and work.
_Avoid_: Journey, route (the route is the path the game chose for a trip)

**Phase**:
Where the person is on the trip: at the building, walking, driving, waiting at the stop, or riding.
_Avoid_: State, status

**Step**:
One item of the numbered list of a travel option: a walk, or a ride on one line from the station where the person boards to the station where the person gets off.
_Avoid_: Leg (the name of a step in the code only), segment, section (a section is the part of a line between two stops)

**Option**:
Also travel option. One way to make the current trip: Walk, Car, or one route by public transport. Each has a time, a length, and an eye button for the map. The card lists the options from the shortest to the longest.
_Avoid_: Alternative (the game keeps none), method, estimate

**Estimate**:
A part of an option that the mod computes itself, because the game does not expose it: every option the game did not choose, and the steps before and after the current step of the chosen one.
_Avoid_: Guess, comparison

**Chosen**:
The option the game took for the current trip. The card marks it "chosen by the game" and builds it from the route of the game as far as the game exposes it.
_Avoid_: Selected, actual

**Current step**:
The step the person is on, or waits for. It comes from the game. The card marks it with bold text and two yellow arrows in the chosen option.
_Avoid_: Current leg, active step, next step

**Station in reach**:
A station whose catchment area holds the origin or the target building.
_Avoid_: Nearby station, catchment station

**Route by lines**:
One way from a station in reach of the origin to a station in reach of the target: one or more steps, each a ride on a line or a walk between two stations. The card names the routes Public transport 1, Public transport 2, in the order of their time; each is an option. Its steps are a numbered list. The card lists the shortest route, the second one when its time is at most 10 % longer, and the chosen one.
_Avoid_: Connection, line option

**Path on the map**:
The steps of an option drawn over the world: a walk in blue, a drive in red, a ride in the colour of its line. The eye button of an option switches it, Show all and Hide all switch every option.
_Avoid_: Overlay, highlight, visualisation

**Map tool**:
The tool of the mod that owns the world layer while a path is shown. It keeps the HUD icons and the entity selector of the game.
_Avoid_: Layer, action

**Locate button**:
The button of the game next to a name that moves the camera to the entity.
_Avoid_: Jump button, go-to
