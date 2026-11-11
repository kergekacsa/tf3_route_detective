-- The Route card of the person window. route_card.res.lua registers RouteCardPlugin at the extension point of the vanilla
-- window, next to the cards Locations, Happiness, and Current Route. The engine reads of the card live in route_state.tl
-- and route_compare.tl; this file renders their data and draws the chosen paths on the map through a tool of its own.

local builtin = ug_require "::/gui/main/builtin.lua" as Builtin
local content_card = ug_require "::/gui/main/content_card.tl" as ContentCard
local engine_react_util = ug_require "::/gui/main/engine_react_util.tl" as EngineReactUtil
local entity_window_util = ug_require "::/gui/entity_window/entity_window_util.tl" as EntityWindowUtil
local hud_icon_toolbox = ug_require "::/gui/main/hud_icon_toolbox.tl" as HudIconToolbox
local hud_react_util = ug_require "::/gui/hud/hud_react_util.tl" as HudReactUtil
local line_react_util = ug_require "::/gui/line_vehicle_mgmt/line_react_util.tl" as LineReactUtil
local react = ug_require "::/gui/main/react.lua" as React
local selector_react_util = ug_require "::/gui/main/selector_react_util.tl" as SelectorReactUtil
local styleutil = ug_require "::/gui/main/styleutil.tl" as StyleUtil
local route_state = ug_require "kacsa_person_route::/person_route/route_state.tl" as PrcRouteStateModule
local route_compare = ug_require "kacsa_person_route::/person_route/route_compare.tl" as PrcRouteCompareModule
local route_lines = ug_require "kacsa_person_route::/person_route/route_lines.tl" as PrcRouteLinesModule

local route_card : PrcRouteCard = {}

-- The id is "<mod id of the base game>::SimPersonEowExtensionPoint", and the mod id of the base game is empty.
local EXTENSION_POINT = { id = "::SimPersonEowExtensionPoint" } as ExtensionPoint<SimPersonEow.SimPersonWidgetPluginParams>
-- The estimate is checked on this timer and recomputed only when the trip changes or the player asks for it.
local COMPARE_CHECK_INTERVAL_SECONDS <const> = 2.0
local CLASS_BODY <const> = "font-scale-body"
local CLASS_LATE <const> = "font-scale-body, logChangeNegative"
local CLASS_GOOD <const> = "font-scale-body, logChangePositive"
local CLASS_HEADLINE <const> = "font-scale-headline"
local LABEL_WEIGHT <const> = 2
local VALUE_WEIGHT <const> = 3
-- Drawing of a path on the map: metres above the edge, line width in metres, and the sampling step of the renderer.
local PATH_OFFSET_Z <const> = 1.5
local PATH_WIDTH <const> = 3.0
local PATH_STEP_SIZE <const> = 1
local LINE_VIEWER_FADING_MIN_HEIGHT <const> = 80
local LINE_VIEWER_FADING_DELTA_HEIGHT <const> = 180
-- The colour of an option, as RGBA: its steps on the map take the light and the dark shade in turns, and the dot in front
-- of its title has the light shade.
local record OptionColor
	light : {number}
	dark : {number}
end
local COLOR_WALK : OptionColor = { light = { 0.40, 0.70, 1.00, 0.90 }, dark = { 0.10, 0.38, 0.80, 0.90 } }
local COLOR_CAR : OptionColor = { light = { 1.00, 0.52, 0.38, 0.90 }, dark = { 0.78, 0.20, 0.10, 0.90 } }
-- The routes by public transport take these in their order, and start again after the last.
local COLORS_LINES : {OptionColor} = {
	{ light = { 0.45, 0.88, 0.50, 0.90 }, dark = { 0.10, 0.58, 0.25, 0.90 } },
	{ light = { 0.80, 0.58, 1.00, 0.90 }, dark = { 0.50, 0.25, 0.80, 0.90 } },
	{ light = { 1.00, 0.85, 0.35, 0.90 }, dark = { 0.80, 0.60, 0.05, 0.90 } },
}
-- The eye of a path that is on the map, and the crossed eye of a path that is not.
local ICON_SHOWN <const> = "::/gui/menu/icons/mod_management/mod-invisible.tga"
local ICON_HIDDEN <const> = "::/gui/line_vehicle_mgmt/icons/symbol_eye.tga"
-- The thin divider is a class of the game. The other classes of the card are in route_card.css.lua.
local CLASS_DIVIDER_THIN <const> = "card-children-separator"
local CLASS_DIVIDER_THICK <const> = "prc-divider-thick"
-- Font classes of route_card.css.lua. They stand alone: a font class of the game on the same text sets the weight too.
local CLASS_BOLD <const> = "prc-bold"
local CLASS_HEADER <const> = "prc-header"
-- An empty component of a fixed width, from route_card.css.lua.
local CLASS_INDENT <const> = "prc-indent"
-- The row of buttons under the options, centred by route_card.css.lua.
local CLASS_ACTIONS <const> = "prc-actions"
-- The space under the title of a block, from route_card.css.lua.
local CLASS_GAP <const> = "prc-gap"
-- The arrows in front of and behind the leg the person is on. route_card.css.lua colours them.
local ICON_CURRENT_START <const> = "::/gui/entity_window/icons/arrow_head_right.tga"
local ICON_CURRENT_END <const> = "::/gui/entity_window/icons/arrow_head_left.tga"
local CLASS_CURRENT <const> = "prc-current"
-- The dot in front of the title of an option, in the colour of the option. route_card.css.lua sizes it.
local ICON_BULLET <const> = "::/gui/main/icons/circle.tga"
local CLASS_BULLET <const> = "prc-bullet"
local TOOL_KEY_PREFIX <const> = "prc_paths_"
-- The view manager names the window of an entity this way (gui/entity_window/view_manager.tl, makeWindowId).
local WINDOW_ID_PREFIX <const> = "temp.view.entity_"

-- The paths each open card wants on the map. The tool reads it every step.
local pathStore : {Engine.Entity : PrcMapPaths} = {}

local function text(value : string, class? : string) : TreeNodeId
	return builtin.TextView{
		meta = { class = class or CLASS_BODY },
		text = value,
	}
end

-- A table cell must not be a layout, so the value sits in a component.
local function row(label : string, value : TreeNodeId) : TreeNodeId
	return builtin.Row{ cells = { text(label), builtin.Component{ layout = builtin.BoxLayout{ child = value } } } }
end

local function horizontal(children : {TreeNodeId}) : TreeNodeId
	return builtin.BoxLayout{
		orientation = builtin.type.Orientation.Horizontal,
		children = children,
	}
end

local function vertical(children : {TreeNodeId}) : TreeNodeId
	return builtin.BoxLayout{
		orientation = builtin.type.Orientation.Vertical,
		children = children,
	}
end

local function seconds(value : number) : string
	if value == nil then
		return ""
	end
	return api.util.formatSeconds(math.floor(math.abs(value)) as integer)
end

-- The game's own text for whole minutes, "{minutes} min" in English.
local function minutes(value : integer) : string
	return (_("prc_minutes"):gsub("{minutes}", tostring(value)))
end

local function destinationTitle(index : integer) : string
	if index == 0 then
		return _("Home")
	elseif index == 1 then
		return _("Shop")
	elseif index == 2 then
		return _("Work")
	end
	return _("prc_unknown")
end

local function phaseTitle(phase : string) : string
	if phase == "building" then
		return _("prc_phase_building")
	elseif phase == "waiting" then
		return _("prc_phase_waiting")
	elseif phase == "riding" then
		return _("prc_phase_riding")
	elseif phase == "walking" then
		return _("prc_phase_walking")
	elseif phase == "driving" then
		return _("prc_phase_driving")
	end
	return _("prc_unknown")
end

-- A note of the compare module is either a text key of this mod or the message of a failed engine call.
local function noteText(note : string) : string
	if note == nil then
		return ""
	end
	if note:sub(1, 4) == "prc_" then
		return _(note)
	end
	return note
end

local function entityName(entity : Engine.Entity, bold? : boolean) : TreeNodeId
	if entity == nil or entity < 0 then
		return text(_("prc_unknown"), bold and CLASS_BOLD or CLASS_BODY)
	end
	return line_react_util.NameTextView{ entity = entity, locationButton = true, styleClass = bold and CLASS_BOLD or nil }
end

local function lineName(line : Engine.Entity, bold? : boolean) : TreeNodeId
	return horizontal({
		line_react_util.ColorWidget{ entity = line },
		line_react_util.NameTextView{ entity = line, locationButton = false, stackEntityOpen = true, styleClass = bold and CLASS_BOLD or nil },
	})
end

local function windowId(personEntity : Engine.Entity) : string
	return WINDOW_ID_PREFIX .. tostring(personEntity)
end

-- The tool that draws the paths. Pushing it on the tool stack shelves the tool of the person window, which hides the
-- window, so the tool shows the window again. Its action keeps the HUD icons and the entity selector of the game.
local record PathToolParam
	personEntity : Engine.Entity
	gameCtx : GameContext
end

local record PathOverlayParam
	personEntity : Engine.Entity
end

local function vec4(c : {number}) : Vec4f
	return api.type.Vec4f.new(c[1], c[2], c[3], c[4])
end

local function pathEdges(path : PrcMapPath, into : {Builtin.Type.EdgeRenderable.Edge})
	local color = vec4(path.color)
	for __, pair in ipairs(path.edges) do
		local edgeId = pair[1]
		local network = edgeId and api.engine.entityExists(edgeId.entity)
			and api.engine.getComponent(edgeId.entity, api.type.ComponentType.TRANSPORT_NETWORK) as Engine.Component.TransportNetwork
		local edge = network and network.edges and network.edges[edgeId.index + 1]
		if edge and edge.geometry then
			local drawn = builtin.type.EdgeRenderable.Edge.new(edge.geometry)
			drawn.colors = { color, color, color }
			drawn.width = PATH_WIDTH
			drawn.offsetZ = PATH_OFFSET_Z
			drawn.stepSize = PATH_STEP_SIZE
			into[#into + 1] = drawn
		end
	end
end

-- Runs inside the action recipe of the tool, so it may use hooks.
local function pathOverlay(param : PathOverlayParam) : {TreeNodeId}
	local version = react.useState(0) as ReactStateT<integer>
	react.onStep(function()
		local store = pathStore[param.personEntity]
		local current = store and store.version or 0
		if current ~= version:old() then
			version:set(current)
		end
	end)
	react.onMount(function()
		api.gui.byId.setVisible(windowId(param.personEntity), true)
	end)

	local store = pathStore[param.personEntity]
	local edges : {Builtin.Type.EdgeRenderable.Edge} = {}
	local lines : {Builtin.Type.LineVisualization} = {}
	local drawnLines : {Engine.Entity : boolean} = {}
	for __, path in ipairs(store and store.paths or {}) do
		if path.edges then
			pathEdges(path, edges)
		elseif path.line and not drawnLines[path.line] then
			drawnLines[path.line] = true
			local visualization = builtin.type.LineVisualization.new()
			visualization.entity = path.line
			visualization.transparency = 1.0
			lines[#lines + 1] = visualization
		end
	end

	local children : {TreeNodeId} = {}
	-- The engine allows one EdgeRenderable per recipe, so every path shares it.
	if #edges > 0 then
		children[#children + 1] = builtin.EdgeRenderable{ edges = edges, ignoreDepth = true }
	end
	if #lines > 0 then
		local snapFactors = hud_react_util.makeDefaultLineViewerSnapFactors()
		children[#children + 1] = builtin.LineViewer{
			selectable = false,
			maxSnapFactorView = snapFactors.view,
			maxSnapFactorWorld = snapFactors.world,
			fadingMinHeight = LINE_VIEWER_FADING_MIN_HEIGHT,
			fadingDeltaHeight = LINE_VIEWER_FADING_DELTA_HEIGHT,
			showLines = lines,
			hiddenLinesTransparent = false,
			showTerminals = false,
		}
	end
	return children
end

local function makePathAction(param : PathToolParam) : function() : TreeNodeId
	return function() : TreeNodeId
		local hudGuiConfig = api.gui.genericRep.get(api.gui.genericRep.find("::/gui/hud/hud_gui_config.gres")).data as HudGuiConfig
		local sfxFinance = api.gui.genericRep.get(api.gui.genericRep.find("::/game_mechanics/finance/sound/finance_sfx.gres")).data as FinanceSFX
		local selectedEntityRef : ReactRefT<Engine.Entity> = react.useRef(-1)
		local children : {TreeNodeId} = {
			builtin.HudIconManagerConfig{
				userParam = {
					accessNotificationCacheFn = param.gameCtx.accessNotificationCacheFn,
				},
				masterRecipe = hud_icon_toolbox.HudIconMasterGame,
				preFilter = selector_react_util.defaultHudIconFilter,
				preFilterTvCarriers = selector_react_util.defaultHudIconFilterTvCarrier,
				showCosts = true,
				showIncome = true,
				incomeSFX = sfxFinance.Income or {},
				costsRenderDistance = hudGuiConfig.renderDistances.Costs,
				visibilityThresholds = hud_react_util.makeDefaultVisibilityThresholds(),
				vehicleIconOffsets = hud_react_util.makeVehicleIconOffsets(hudGuiConfig.vehicleIconOffsets),
			},
			selector_react_util.makeDefaultSelectorIfMouse(param.gameCtx.rendererComponent, selectedEntityRef),
			selector_react_util.makeDefaultSelectorTooltipsIfMouse(selectedEntityRef),
		}
		for __, node in ipairs(pathOverlay({ personEntity = param.personEntity })) do
			children[#children + 1] = node
		end
		return builtin.ActionDescriptor{
			horizontalPromptList = true,
			children = children,
			terrainCirclePolicy = "Never",
		}
	end
end

local PathTool = react.RegisterTool({
	name = "PrcPathTool",
	push = function(ctx : Builtin.ToolStackContext<PathToolParam>, param : PathToolParam)
		ctx.setActionFn(makePathAction(param), TOOL_KEY_PREFIX .. tostring(param.personEntity))
		api.gui.byId.setVisible(windowId(param.personEntity), true)
	end,
	pop = function(_ctx : Builtin.ToolStackContext<PathToolParam>, _param : PathToolParam)
	end,
	shelve = function(ctx : Builtin.ToolStackContext<PathToolParam>, param : PathToolParam, shelve : boolean)
		if not shelve then
			ctx.setActionFn(makePathAction(param), TOOL_KEY_PREFIX .. tostring(param.personEntity))
			api.gui.byId.setVisible(windowId(param.personEntity), true)
		end
	end,
} as ReactToolDefinition<PathToolParam>)

local function toolStackApi(gameCtx : GameContext) : Builtin.ToolStackAPI
	return gameCtx.toolStack:get():getApi()
end

local record DestinationButtonParam
	entity : Engine.Entity
	destinationIndex : integer
end

local DestinationButton = react.RegisterRecipe("PrcDestinationButton", function(param : DestinationButtonParam) : TreeNodeId
	local content = horizontal({
		entity_window_util.GetDestinationIcon{ destinationIndex = param.destinationIndex },
		text(destinationTitle(param.destinationIndex), CLASS_HEADLINE),
	})
	if param.entity == nil or param.entity < 0 then
		return content
	end
	return horizontal({
		builtin.Button{
			content = content,
			onClick = function()
				react.fireEvent(nil, "selectEntity", { entity = param.entity, stack = true })
			end,
		},
		line_react_util.LocateButton{ entity = param.entity },
	})
end)

local record PersonParam
	personEntityId : Engine.Entity
	gameCtx : GameContext
end

local RouteSummary = react.RegisterRecipe("PrcRouteSummary", function(param : PersonParam) : TreeNodeId
	local state = engine_react_util.useStepState(function() : PrcRouteState
		return route_state.read(param.personEntityId)
	end)
	local s = state:old()
	if s == nil then
		return builtin.BoxLayout{ child = text(_("prc_unknown")) }
	end

	local children : {TreeNodeId} = {}
	if s.phase == "building" then
		children[#children + 1] = text(phaseTitle(s.phase))
		children[#children + 1] = DestinationButton{ entity = s.targetEntity, destinationIndex = s.targetIndex }
	else
		children[#children + 1] = DestinationButton{ entity = s.originEntity, destinationIndex = s.originIndex }
		if s.moveMode ~= nil then
			children[#children + 1] = entity_window_util.GetMoveModeIcon(s.moveMode)
		end
		children[#children + 1] = text(phaseTitle(s.phase))
		children[#children + 1] = DestinationButton{ entity = s.targetEntity, destinationIndex = s.targetIndex }
	end
	return horizontal(children)
end)

local function placeRows(s : PrcRouteState) : {TreeNodeId}
	local rows : {TreeNodeId} = {}
	local function place(label : string, entity : Engine.Entity, town : Engine.Entity)
		if entity == nil or entity < 0 then
			return
		end
		local children : {TreeNodeId} = { entityName(entity) }
		if town ~= nil then
			-- The text around the town: "in {town}" in English.
			local before, after = _("prc_in_town"):match("^(.-){town}(.*)$")
			local line : {TreeNodeId} = { builtin.Component{ meta = { class = CLASS_INDENT } } }
			if before ~= nil and before ~= "" then
				line[#line + 1] = text(before)
			end
			line[#line + 1] = entityName(town)
			if after ~= nil and after ~= "" then
				line[#line + 1] = text(after)
			end
			children[#children + 1] = horizontal(line)
		end
		rows[#rows + 1] = row(label, vertical(children))
	end
	if s.phase ~= "building" then
		place(_("prc_from"), s.originEntity, s.originTown)
	end
	place(s.phase == "building" and _("prc_at") or _("prc_to"), s.targetEntity, s.targetTown)
	return rows
end

local function legRows(s : PrcRouteState) : {TreeNodeId}
	local rows : {TreeNodeId} = {}
	if s.waitingSeconds ~= nil then
		rows[#rows + 1] = row(_("prc_waiting_for"), text(seconds(s.waitingSeconds), s.waitingLate and CLASS_LATE or CLASS_BODY))
	end
	if s.waitingVehicle ~= nil then
		rows[#rows + 1] = row(_("prc_next_vehicle"), entityName(s.waitingVehicle))
	end
	return rows
end

-- Which options the player switched on for the map, by key.
local type Shown = {string : boolean}

local function showButton(key : string, shown : Shown, setShown : function(string, boolean)) : TreeNodeId
	local on = shown[key] == true
	return builtin.Button{
		meta = { tooltip = on and _("prc_hide") or _("prc_show") },
		content = builtin.ImageView{
			path = on and ICON_SHOWN or ICON_HIDDEN,
			scaling = builtin.type.ImageViewScaling.AutoFit,
		},
		onClick = function()
			setShown(key, not on)
		end,
	}
end

-- One leg of a route by lines as an item of a numbered list: the number with the method (the line, or Walk), its time in
-- minutes with the average wait for the line in brackets, then the
-- place the leg starts at, then the place it ends at, both indented. The leg the person is on, or waits for, is bold and has an arrow
-- at each end of its first line.
local function legItem(number : integer, leg : PrcRouteLeg) : TreeNodeId
	local bold = leg.current == true
	local class = bold and CLASS_BOLD or CLASS_BODY
	local function arrow(path : string) : TreeNodeId
		return builtin.ImageView{ meta = { class = CLASS_CURRENT }, path = path, scaling = builtin.type.ImageViewScaling.AutoFit }
	end
	local head : {TreeNodeId} = {}
	if bold then
		head[#head + 1] = arrow(ICON_CURRENT_START)
	end
	head[#head + 1] = text(tostring(number) .. ".", class)
	if leg.line ~= nil then
		head[#head + 1] = lineName(leg.line, bold)
		if leg.waitSeconds == nil then
			head[#head + 1] = text(_("prc_no_frequency"))
		end
	else
		head[#head + 1] = entity_window_util.GetMoveModeIcon(api.type["enum"].MoveMode.WALK)
		head[#head + 1] = text(_("Walk"), class)
	end
	if leg.minutes ~= nil then
		local time = minutes(leg.minutes)
		if leg.waitMinutes ~= nil then
			time = time .. " " .. (_("prc_step_wait"):gsub("{time}", minutes(leg.waitMinutes)))
		end
		head[#head + 1] = text(time, class)
	end
	if bold then
		head[#head + 1] = arrow(ICON_CURRENT_END)
	end
	local lines : {TreeNodeId} = { horizontal(head) }
	local function place(entity : Engine.Entity)
		if entity ~= nil then
			lines[#lines + 1] = horizontal({ builtin.Component{ meta = { class = CLASS_INDENT } }, entityName(entity, bold) })
		end
	end
	place(leg.fromStation or leg.fromBuilding)
	place(leg.toStation or leg.toBuilding)
	return vertical(lines)
end

local function optionKey(option : PrcOption) : string
	local parts : {string} = { option.kind }
	for __, leg in ipairs(option.kind == "lines" and option.legs or {}) do
		parts[#parts + 1] = tostring(leg.line) .. "/" .. tostring(leg.fromStopIndex) .. "/" .. tostring(leg.toStopIndex)
	end
	return table.concat(parts, ":")
end

-- The colour of each option of a result, at the index of the option.
local function optionColors(c : PrcCompareResult) : {OptionColor}
	local colors : {OptionColor} = {}
	local lineNumber = 0
	for i, option in ipairs(c.options) do
		if option.kind == "car" then
			colors[i] = COLOR_CAR
		elseif option.kind == "lines" then
			colors[i] = COLORS_LINES[lineNumber % #COLORS_LINES + 1]
			lineNumber = lineNumber + 1
		else
			colors[i] = COLOR_WALK
		end
	end
	return colors
end

-- One option as a table: on the left its title behind a dot in its colour, its time and length with the eye, and the mark
-- of the choice of the game; on the right, for a route by lines, its legs as a numbered list, one row per leg.
local function optionTable(option : PrcOption, title : string, color : OptionColor, shown : Shown, setShown : function(string, boolean)) : TreeNodeId
	local summary : {TreeNodeId} = { horizontal({
		builtin.ImageView{
			meta = { class = CLASS_BULLET, styleSheet = styleutil.makeStyle{ color = color.light } },
			path = ICON_BULLET,
			scaling = builtin.type.ImageViewScaling.AutoFit,
		},
		text(title, CLASS_HEADLINE),
	}) }
	if option.available then
		-- A route by lines shows whole minutes, so the minutes of its legs add up to it.
		local numbers = option.kind == "lines" and minutes(option.minutes) or seconds(option.seconds)
		if option.meters ~= nil and option.meters > 0 then
			numbers = numbers .. ", " .. api.util.formatLength(option.meters)
		end
		summary[#summary + 1] = horizontal({ text(numbers), showButton(optionKey(option), shown, setShown) })
	else
		summary[#summary + 1] = text(noteText(option.note))
	end
	if option.chosen then
		summary[#summary + 1] = text(_("prc_chosen"), CLASS_GOOD)
	end

	local function cells(left : TreeNodeId, right : TreeNodeId) : TreeNodeId
		return builtin.Row{ cells = {
			builtin.Component{ layout = builtin.BoxLayout{ child = left } },
			builtin.Component{ layout = builtin.BoxLayout{ child = right } },
		} }
	end
	local legs = option.kind == "lines" and option.legs or {}
	local rows : {TreeNodeId} = { cells(vertical(summary), legs[1] and legItem(1, legs[1]) or vertical({})) }
	for i = 2, #legs do
		rows[#rows + 1] = cells(vertical({}), legItem(i, legs[i]))
	end
	return builtin.TableLayout{ columnWeights = { LABEL_WEIGHT, VALUE_WEIGHT }, rows = rows }
end

-- The options with a thin divider between them. The routes by public transport are numbered in their order.
local function optionsNodes(c : PrcCompareResult, shown : Shown, setShown : function(string, boolean)) : {TreeNodeId}
	local nodes : {TreeNodeId} = {}
	if c == nil then
		return nodes
	end
	if c.error ~= nil then
		nodes[1] = text(noteText(c.error))
		return nodes
	end
	local colors = optionColors(c)
	local lineNumber = 0
	for i, option in ipairs(c.options) do
		local title = _("Walk")
		if option.kind == "car" then
			title = _("Car")
		elseif option.kind == "lines" then
			lineNumber = lineNumber + 1
			title = option.available and (_("prc_public_transport") .. " " .. tostring(lineNumber)) or _("prc_public_transport")
		end
		if i > 1 then
			nodes[#nodes + 1] = builtin.Component{ meta = { class = CLASS_DIVIDER_THIN } }
		end
		nodes[#nodes + 1] = optionTable(option, title, colors[i], shown, setShown)
	end
	return nodes
end

-- What the map tool draws for the options the player switched on: the edges of each leg in the colour of its option, the
-- light and the dark shade in turns, and the whole line of a ride whose edges are not known.
local function mapPaths(c : PrcCompareResult, shown : Shown) : {PrcMapPath}
	local paths : {PrcMapPath} = {}
	if c == nil or c.options == nil then
		return paths
	end
	local colors = optionColors(c)
	for i, option in ipairs(c.options) do
		local key = optionKey(option)
		for step, leg in ipairs(shown[key] and option.legs or {}) do
			if leg.edges ~= nil then
				paths[#paths + 1] = { key = key, edges = leg.edges, color = step % 2 == 1 and colors[i].light or colors[i].dark }
			elseif leg.line ~= nil then
				paths[#paths + 1] = { key = key, line = leg.line }
			end
		end
	end
	return paths
end

local function signatureOf(paths : {PrcMapPath}, tripKey : string) : string
	local parts : {string} = { tripKey or "" }
	for __, path in ipairs(paths) do
		parts[#parts + 1] = path.key .. "=" .. tostring(path.edges and #path.edges or path.line)
	end
	return table.concat(parts, "|")
end

local RouteDetails = react.RegisterRecipe("PrcRouteDetails", function(param : PersonParam) : TreeNodeId
	local gameCtx = param.gameCtx
	local state = engine_react_util.useStepState(function() : PrcRouteState
		return route_state.read(param.personEntityId)
	end)
	local refreshToken : ReactRefT<integer> = react.useRef(0)
	local compared = engine_react_util.useStepStateTimer(function(old : PrcCompareResult) : PrcCompareResult
		local s = route_state.read(param.personEntityId)
		if s == nil or s.phase == "building" then
			return nil
		end
		local tripKey = tostring(s.originEntity) .. ":" .. tostring(s.targetEntity) .. ":" .. s.phase .. ":" .. tostring(s.line) .. ":"
			.. tostring(s.leaveStopIndex) .. ":" .. tostring(refreshToken:get())
		if old ~= nil and old.tripKey == tripKey then
			return old
		end
		local result = route_compare.compare(param.personEntityId, s)
		result.tripKey = tripKey
		return result
	end, COMPARE_CHECK_INTERVAL_SECONDS, function(a : PrcCompareResult, b : PrcCompareResult) : boolean
		if a == nil or b == nil then
			return a == b
		end
		return a.tripKey == b.tripKey
	end)
	local shownState = react.useState({} as Shown) as ReactStateT<Shown>
	local pushedRef : ReactRefT<boolean> = react.useRef(false)
	local signatureRef : ReactRefT<string> = react.useRef("")

	local s = state:old()
	local c = compared:old()
	local shown = shownState:old()

	local function setShown(key : string, on : boolean)
		local updated : Shown = {}
		for k, v in pairs(shownState:old()) do
			updated[k] = v
		end
		updated[key] = on or nil
		shownState:set(updated)
	end
	local function setAll(on : boolean)
		local updated : Shown = {}
		for __, option in ipairs(on and c ~= nil and c.options or {}) do
			if option.available then
				updated[optionKey(option)] = true
			end
		end
		shownState:set(updated)
	end

	-- Hand the paths of the options that are switched on to the tool, and push or pop the tool as the choice changes.
	local wanted = mapPaths(c, shown)
	local signature = signatureOf(wanted, c and c.tripKey or nil)
	if signature ~= signatureRef:get() then
		signatureRef:set(signature)
		local store = pathStore[param.personEntityId]
		pathStore[param.personEntityId] = { version = (store and store.version or 0) + 1, paths = wanted }
	end
	local toolKey = TOOL_KEY_PREFIX .. tostring(param.personEntityId)
	if #wanted > 0 and not pushedRef:get() then
		pushedRef:set(true)
		toolStackApi(gameCtx).push(PathTool, toolKey, { personEntity = param.personEntityId, gameCtx = gameCtx }, true)
	elseif #wanted == 0 and pushedRef:get() then
		pushedRef:set(false)
		toolStackApi(gameCtx).pop(PathTool, toolKey)
	end
	react.onUnmount(function()
		pathStore[param.personEntityId] = nil
		if pushedRef:get() then
			pushedRef:set(false)
			toolStackApi(gameCtx).pop(PathTool, toolKey)
		end
	end)

	if s == nil then
		return builtin.BoxLayout{ child = text(_("prc_unknown")) }
	end

	local rows : {TreeNodeId} = {}
	for __, r in ipairs(placeRows(s)) do
		rows[#rows + 1] = r
	end
	for __, r in ipairs(legRows(s)) do
		rows[#rows + 1] = r
	end

	local children : {TreeNodeId} = {
		builtin.TableLayout{ columnWeights = { LABEL_WEIGHT, VALUE_WEIGHT }, rows = rows },
	}
	if s.phase ~= "building" then
		children[#children + 1] = builtin.Component{ meta = { class = CLASS_DIVIDER_THICK } }
		children[#children + 1] = text(_("prc_options_title"), CLASS_HEADER)
		children[#children + 1] = builtin.Component{ meta = { class = CLASS_GAP } }
		local options = optionsNodes(c, shown, setShown)
		if #options == 0 then
			children[#children + 1] = text(_("prc_estimate_pending"))
		end
		for __, node in ipairs(options) do
			children[#children + 1] = node
		end
		children[#children + 1] = builtin.Component{ meta = { class = CLASS_DIVIDER_THIN } }
		children[#children + 1] = builtin.Component{ meta = { class = CLASS_ACTIONS }, layout = horizontal({
			builtin.Button{
				content = text(_("prc_recalculate")),
				onClick = function()
					route_lines.forgetEntrances()
					refreshToken:set(refreshToken:get() + 1)
				end,
			},
			builtin.Button{
				content = text(_("prc_show_all")),
				onClick = function() setAll(true) end,
			},
			builtin.Button{
				content = text(_("prc_hide_all")),
				onClick = function() setAll(false) end,
			},
		}) }
	end
	return builtin.BoxLayout{
		orientation = builtin.type.Orientation.Vertical,
		children = children,
	}
end)

route_card.RouteCardPlugin = react.RegisterPluginRecipe(EXTENSION_POINT, "PrcRouteCardPlugin", function(extensionParams : SimPersonEow.SimPersonWidgetPluginParams) : TreeNodeId
	local uniqueCardKey = tostring(react.getCurrentRecipeId())
	return builtin.BoxLayout{
		child = content_card.ContentCard{
			title = _("prc_card_title"),
			initialCalloutTextPermanent = "",
			recipeAndParamPermanent = content_card.makeRecipeAndParam(RouteSummary, { personEntityId = extensionParams.entityId }),
			initialCalloutTextCollapsible = "",
			recipeAndParamCollapsible = content_card.makeRecipeAndParam(RouteDetails, { personEntityId = extensionParams.entityId, gameCtx = extensionParams.gameCtx }),
			setCollapsibleExpanded = function(v : boolean) extensionParams.setCollapsibleExpanded(uniqueCardKey, v) end,
			collapsibleExpanded = extensionParams.getCollapsibleExpanded(uniqueCardKey),
			gameCtx = extensionParams.gameCtx,
			showOnRightSide = extensionParams.showCalloutOnRightSide,
		}
	}
end)

return route_card
