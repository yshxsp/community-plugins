local STATE_KEY = "yt_music.state"

local theme = require("./utils/theme.luau")
local state = require("./views/state.luau")
local rerender = require("./views/rerender.luau")
local timer = require("./utils/timer.luau")
local sidebar_comp = require("./views/components/sidebar.luau")
local playerbar_comp = require("./views/components/playerbar.luau")
local auth_comp = require("./views/components/auth.luau")
local home_comp = require("./views/components/home.luau")
local discover_comp = require("./views/components/discover.luau")
local playlist_comp = require("./views/components/playlist.luau")
local queue_comp = require("./views/components/queue.luau")
local settings_comp = require("./views/components/settings.luau")
local offline_comp = require("./views/components/offline.luau")
local artist_comp = require("./views/components/artist.luau")
local library_comp = require("./views/components/library.luau")

theme.corner_radius_scale = noctalia.getSetting("shell.corner_radius_scale") or 1.0
theme.radius = 12 * theme.corner_radius_scale

local function build_content()
	local content = {}

	local page_builders = {
		playlist = playlist_comp.build,
		discover = discover_comp.build,
		queue = queue_comp.build,
		settings = settings_comp.build,
		offline = offline_comp.build,
		artist = artist_comp.build,
		library = library_comp.build,
	}

	local builder = page_builders[state.view.content_page]
	if builder then
		for _, item in ipairs(builder()) do
			table.insert(content, item)
		end
	else
		if not state.logged_in() then
			table.insert(content, auth_comp.build_signin_prompt())
		else
			for _, item in ipairs(home_comp.build()) do
				table.insert(content, item)
			end
		end
	end

	return ui.scroll(
		{ key = "content-scroll", flexGrow = 1, gap = 12, paddingH = 16, paddingV = 12, radius = theme.radius },
		content
	)
end

local function render_panel()
	local body = {}

	table.insert(
		body,
		ui.row({
			key = "main-row",
			align = "stretch",
			flexGrow = 1,
			gap = 12,
			borderWidth = 0,
			radius = theme.radius,
		}, {
			sidebar_comp.build_sidebar(),

			ui.column({
				key = "right-col",
				flexGrow = 1,
				borderWidth = 0,
				gap = 0,
				radius = theme.radius,
			}, {
				sidebar_comp.build_topbar(),
				build_content(),
			}),
		})
	)

	table.insert(body, ui.row({ key = "player-spacer", height = 12, borderWidth = 0, radius = theme.radius }))

	table.insert(body, playerbar_comp.build())

	panel.render(ui.column({
		key = "ytmusic-root",
		gap = 0,
		padding = 0,
		flexGrow = 1,
		radius = theme.radius,
	}, body))
end

-- A closed panel keeps its runtime and watchers alive; rebuilding the whole
-- UI tree for snapshots nobody can see is wasted work, so renders wait for
-- onOpen.
local visible = false
rerender.set(function()
	if visible then
		render_panel()
	end
end)

-- Once-a-second position (and bitrate) updates from the service.
local TICK_KEY = "yt_music.tick"
local function apply_tick(t)
	local player = state.data.player
	if type(t) ~= "table" or type(player) ~= "table" or t.id ~= player.id then
		return
	end
	player.position = t.position
	player.bitrate = t.bitrate
	rerender.call()
end

function onSidebarHover(hover_state, key)
	state.hover_update("sidebar", hover_state, key)
end
function onCardHover(hover_state, key)
	state.hover_update("card", hover_state, key)
end
function onTrackHover(hover_state, key)
	state.hover_update("track", hover_state, key)
end

function onQueueTrackDropped(payload, value)
	queue_comp.on_track_dropped(payload, value)
end

function onTrackContextMenu(actionId, trackId)
	state.handle_track_context_menu(actionId, trackId)
end

function onOpen(_context)
	visible = true
	theme.corner_radius_scale = noctalia.getSetting("shell.corner_radius_scale") or 1.0
	theme.radius = 12 * theme.corner_radius_scale
	local curr = noctalia.state.get(STATE_KEY)
	if curr then
		state.apply(curr)
	end
	apply_tick(noctalia.state.get(TICK_KEY))
	render_panel()
end

function onClose()
	visible = false
end

if noctalia.state and noctalia.state.watch then
	noctalia.state.watch(STATE_KEY, state.apply)
	noctalia.state.watch(TICK_KEY, apply_tick)
	local curr = noctalia.state.get(STATE_KEY)
	if curr then
		state.apply(curr)
	end
end

render_panel()

-- Drives utils/timer.luau (search debounce, UI delays) for this entry.
function update()
	timer.tick()
end
timer.tick()
