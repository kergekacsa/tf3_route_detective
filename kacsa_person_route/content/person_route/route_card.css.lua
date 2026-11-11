-- The styles of the Route card: the thick divider between its blocks, the space under a block title, the indent of the town line and of the places of a leg, the centred row of buttons, the dot of an option,
-- the colour of the arrows of the current leg, and bold text for the block titles and for the leg the person is on. The thin divider and the font of plain text
-- are classes of the game.
local ssu = require "::/gui/main/stylesheetutil.lua"

-- Width of a content card of an entity window when the size table of the game is not readable.
local FALLBACK_CARD_WIDTH = 400
local THICK_DIVIDER_HEIGHT = 3
local THICK_DIVIDER_MARGIN = 8
-- The indent of the town line under a building and of the places of a leg: about four characters of the body font.
local INDENT_WIDTH = 28
-- The space under the title of a block.
local GAP_HEIGHT = 10
-- The dot in front of the title of an option, and the space between the dot and the title.
local BULLET_SIZE = 8
local BULLET_MARGIN = 6
-- The font sizes of the classes font-scale-body and font-scale-headline of the game.
local BODY_FONT_SIZES = { small = 14, medium = 17, large = 19 }
local HEADLINE_FONT_SIZES = { small = 16, medium = 19, large = 21 }

function data()
	local result = {}
	local a = ssu.makeAdder(result)

	local width = FALLBACK_CARD_WIDTH
	local okSizes, sizes = pcall(require, "::/gui/entity_window/entity_window_sizes.lua")
	if okSizes and type(sizes) == "table" and type(sizes.InnerCardWidth) == "number" then
		width = sizes.InnerCardWidth
	end
	local colorDefault = api.gui.genericRep.get(api.gui.genericRep.find("::/gui/main/default_colors.gres")).data

	a("R::InfoCalloutWrapper R::Component!prc-divider-thick", {
		gravity = { 0.5, -1 },
		size = { width, THICK_DIVIDER_HEIGHT },
		margin = { THICK_DIVIDER_MARGIN, 0, THICK_DIVIDER_MARGIN, 0 },
		backgroundColor = colorDefault.BaseVeryLight,
	})
	a("R::InfoCalloutWrapper R::Component!prc-indent", {
		size = { INDENT_WIDTH, 1 },
	})
	a("R::InfoCalloutWrapper R::Component!prc-actions", {
		gravity = { 0.5, -1 },
	})
	a("R::InfoCalloutWrapper R::Component!prc-gap", {
		size = { 1, GAP_HEIGHT },
	})
	a("R::InfoCalloutWrapper ImageView!prc-bullet", {
		size = { BULLET_SIZE, BULLET_SIZE },
		gravity = { 0, 0.5 },
		margin = { 0, BULLET_MARGIN, 0, 0 },
	})
	a("R::InfoCalloutWrapper ImageView!prc-current", {
		color = colorDefault.Warning,
	})
	-- The same form as the font classes of the game (gui/main/font_scaling.css.lua): the weight by the class, the size by
	-- the font size class of the interface.
	local function font(class, fontSizes)
		a("!" .. class, { fontWeight = "Bold" })
		a("!font-small !" .. class, { fontSize = fontSizes.small })
		a("!font-medium !" .. class, { fontSize = fontSizes.medium })
		a("!font-large !" .. class, { fontSize = fontSizes.large })
	end
	font("prc-bold", BODY_FONT_SIZES)
	font("prc-header", HEADLINE_FONT_SIZES)

	return result
end
