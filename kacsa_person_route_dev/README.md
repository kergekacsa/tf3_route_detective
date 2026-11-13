# Route Detective

Route Detective (mod id `kacsa_person_route`) is a Transport Fever 3 mod that adds one card, "Route", to the window of a person. The card shows the options of the person's current trip: on foot, by car, and by public transport. The option the game chose shows the route of the game as far as the game exposes it. The terms are in `CONTEXT.md` and the structure in `ARCHITECTURE.md`.

## What the card shows

The top row names the origin, the way the person moves (walk, car, or lines), the phase of the trip (at the building, walking, driving, waiting at the stop, riding), and the target. The origin and target buttons open the building.

The card opens by itself when the window of a person opens. The mod setting "Show the route when a person is selected" switches that off; the card then opens when you click it.

The expandable part has two blocks, with a thick divider between them:

- **The trip.** From and To: the building, and under it the town ("in Gawler", indented). For a person who waits at a stop: the wait so far (red after two minutes, the point where the game turns the happiness trend negative), and the vehicle the person waits for.
- **Options.** The ways to make the current trip, from the shortest to the longest, with a thin divider between them; of options that show the same time, the one the game chose comes first: Walk, Car, and the routes by public transport ("Public transport 1", "Public transport 2"). The card lists the shortest route by public transport, the second one when its time is at most 10 % longer, and the route the game chose. A dot stands in front of the title of each option. Each option shows its time and its length with an eye button, and the mark "chosen by the game" on the option the game took. A route by public transport lists its steps to the right of that, as a numbered list. Each step names the method (the line, or Walk) and its time in minutes; a ride has the average wait for the line in brackets after it, for example "3 min (5 min waiting)". The times of the steps and their waits add up to the time of the option, which a route by public transport shows in whole minutes. Under the method, indented, stand the place the step starts at and the place it ends at. A route can use any number of lines and walks between stations in reach of each other. Walks that follow each other are one step: one walk from the start of the first to the end of the last, on the path the pathfinder of the game finds between these two places. It starts with the walk from the origin building to the first station and ends with the walk from the last station to the target building.

The options are computed once per step of the trip, and again when you press Recalculate.

### The option the game chose

The game exposes only the step a person is on: the path the person walks or drives now, and the line of the current ride with its two stops. The card builds the chosen option from that:

- **Car or walk chosen, and the person is on the way:** the option is the path of the game, with its real length. Nothing is estimated.
- **Public transport chosen:** the step between the two yellow arrows, in bold text, comes from the game: the person rides it or waits for it now. The steps before it and after it are the mod's estimate.

The other options are always the mod's estimate.

## Paths on the map

The option the game chose is on the map as soon as the card is open, until you switch it off with its eye button. The eye button of an option draws it on the map in the colour of the option: Walk blue, Car red, and the routes by public transport green, purple, and yellow in their order. The dot in front of the title of an option has the same colour. The steps of an option take a light and a dark shade of the colour in turns, so each step stands apart from the next. The width of the line tells how the person moves: a ride on public transport is a thick line, a drive a normal one, and a walk a thin one. A ride runs from the stop where the person boards to the stop where the person leaves. When the game finds no path between two stops, the whole line is drawn instead, in the colour of the line. You can even show all options at once: Show all and Hide all switch every option. The paths stay on the map while the window is open and the eye is on. While a path is shown, the mod's own map tool is active: the game still shows its HUD icons and lets you click entities, and the person window stays open.

## Limits

- The game computes a route once and keeps only the result. The card cannot show which alternatives the game rejected or why.
- The estimated steps of the chosen option can differ from what the person then does. The game can choose another route than the best one the mod finds.
- The time of an option is not what the game compares. The game compares a cost that a script cannot read, and it multiplies the cost of lines by a factor per town (a marketing campaign, or a mod such as Transit Preference). So the game can choose an option that the card shows as much slower.
- A ride uses the section times of one vehicle of the line, and half the interval between vehicles as the wait. The ride the person is on has this average wait too, because the person had to wait for it; the real wait so far is in the first block.
- The game gives a section time of 0 for a section that no vehicle of the line has driven since the load. A ride over such a section shows too short a time until a vehicle has driven it.
- A line can stop at one station twice in one round. An estimated ride then starts at the visit that gives the shorter ride. Of two rides with the same time, the one over fewer sections of the line counts. The ride of the current step keeps the stops the game names.
- The minutes of the steps are rounded so that they add up to the minutes of the option. A short step can show "0 min".
- The walk and car estimates use the shortest path in the network and the speed limits of the edges. They ignore traffic and waiting at junctions. Where the game does not give the curve speed limit of an edge, the edge counts with its speed limit alone.
- A walking path is drawn over whole edges, also where the person uses only a part of an edge.
- The section of a line between two stops is the path the game's pathfinder finds between the two stops. A vehicle of the line can take another path when the line has waypoints.
- The walk and car estimates start and end at the street of the parcels of a building. An industry has no parcels, so a trip from or to an industry shows "no access nodes" for walk and car unless the person walks or drives it now.
- A walk to or from a station with entrances starts or ends at the street next to an entrance. The pathfinder picks the entrance that gives the shortest walk, and the way inside the station is not counted. A stop without entrances of its own is its platform, or the street edge nearest to it.
- The path of a walk comes from the pathfinder function of the game. It gives paths of different lengths for the two directions of the same walk, so the mod asks for both and takes the shorter one. The function does not walk through a station or a building. Where a station interrupts the pavement, the path can cross the street and come back, which a person in the game need not do.
- The entrances of a station are read once and kept, because the read takes up to a quarter of a second for a large station. Recalculate reads them again.
- When you click another entity while paths are shown, the game opens that window on top and hides the paths until you return to the person window.
- The texts in the 12 languages besides English are machine-made and not checked by native speakers. Where the game has a text with the same meaning (the phases, Unknown, Show all, Public transport, no path), the mod uses the text of the game, and the other texts use the game's word for route, frequency, vehicle, line, station, and building.

## Tests

```powershell
cd kacsa_person_route_dev
.\tests\run.ps1
```

The tests compile the data modules with the Teal compiler and run them against a stub of the game's `api`. They prove the logic, not that the game accepts a call. `tl check ../kacsa_person_route/content/person_route/<file>.tl`, run in `kacsa_person_route_dev`, type-checks a file against the game's definitions (`tlconfig.lua`).

## Release

The rules and the steps of an upload are in `..\PUBLISHING.md`. The mod page text is `kacsa_person_route\_metadata\modinfo.json`. `C:\Users\Kacsa\tools\icon-gen\make-person-route.ps1` builds the logo (`image_00.jpg`), the cover (`_metadata\0.png`), and the gallery pictures (`_metadata\1.png` to `3.png`) from the screenshots in that folder; its parameters set the name and the two lines of text.

`strings.json` holds the texts of the card in the 13 languages of the game. In `C:\Users\Kacsa\tools\strings-gen`, `person-route-compare.js` prints the texts of the mod next to the texts of the game, and `person-route-apply.js` sets the texts that follow the game and checks that every language has every key (`--check` writes nothing).
