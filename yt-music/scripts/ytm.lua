-- yt-music companion script, loaded into mpv with --script.
--
-- Pushes playback state to the plugin as `client-message` events on the IPC
-- socket, so the plugin keeps one idle `nc` connection instead of a shell loop
-- that polled mpv every second:
--   * observed properties are forwarded as {event="property-change",...};
--   * time-pos goes out once a second, just after each whole second of the
--     position, as {request_id=100}, audio-bitrate every tenth tick as
--     {request_id=200}; no ticks while paused;
--   * `script-message ytm-sync` re-sends every observed value (the plugin
--     connects after mpv has started and would miss the first notifications).
--
-- With --script-opts=ytm-cache=<path>, the track is saved for offline use
-- straight from mpv's demuxer cache once the whole file is buffered: no second
-- download. Success is reported as {event="ytm-cached"}, failure as
-- {event="ytm-cache-failed"} so the plugin can fall back to yt-dlp;
-- {event="ytm-cache-started"} marks a dump in progress.

local utils = require("mp.utils")

local opts = { cache = "", partial = "" }
require("mp.options").read_options(opts, "ytm")

local function emit(t)
	mp.commandv("script-message", "ytm", utils.format_json(t))
end

local WATCHED = {
	"pause",
	"duration",
	"eof-reached",
	"audio-codec-name",
	"audio-params/samplerate",
	"playlist-pos",
}

-- A freshly minted googlevideo URL answers 403 until it is ~2.1-2.7 s old
-- (measured from yt-dlp's exit). First line of defence: on_load_fail holds the
-- failed open and retries it in place once the URL is ~2.9 s old, so mpv
-- never leaves the track. mpv runs this hook once per load; the cache-busting
-- parameter makes it count as a new URL.
local WARM_AFTER = 2.9
local started_at = mp.get_time()

mp.add_hook("on_load_fail", 50, function(hook)
	local url = mp.get_property("stream-open-filename") or ""
	if mp.get_property_number("playlist-pos") ~= 1 or not url:match("^https?://") then
		return
	end
	hook:defer()
	mp.add_timeout(math.max(0.5, WARM_AFTER - (mp.get_time() - started_at)), function()
		mp.set_property("stream-open-filename", url .. "&ytmretry=1")
		hook:cont()
	end)
end)

-- Fallback if that retry fails too: mpv falls through to the silent dummy;
-- replay the track every 0.5 s for up to 10 s, hiding that playlist move from
-- the plugin (it would read it as a skip). Each round trip through the dummy
-- costs RSS, hence the in-place retry above. Only a final failure is reported.
local RETRY_DELAY = 0.5
local MAX_RETRIES = 20
local retries = 0
local retrying = false

-- Entries 0 and 2 are the silent dummies that give MPRIS its prev/next; their
-- endless duration changes many times a second. Only the real track's values
-- (plus pause and the playlist moves the plugin reads as skips) go out.
local function on_track()
	return mp.get_property_number("playlist-pos") == 1
end

local function forward(name, value)
	if retrying and (name == "playlist-pos" or name == "eof-reached") then
		return
	end
	if name ~= "playlist-pos" and name ~= "pause" and not on_track() then
		return
	end
	emit({ event = "property-change", name = name, data = value })
end

for _, name in ipairs(WATCHED) do
	mp.observe_property(name, "native", forward)
end

mp.register_event("end-file", function(ev)
	if ev.reason ~= "error" or ev.playlist_entry_id ~= mp.get_property_number("playlist/1/id") then
		return
	end
	if retries < MAX_RETRIES then
		retries = retries + 1
		retrying = true
		mp.add_timeout(RETRY_DELAY, function()
			mp.commandv("playlist-play-index", "1")
		end)
	else
		retrying = false
		emit({ event = "ytm-load-failed", file_error = ev.file_error })
	end
end)

mp.register_event("file-loaded", function()
	if retrying and mp.get_property_number("playlist-pos") == 1 then
		retrying = false
		forward("playlist-pos", 1)
	end
end)

mp.register_script_message("ytm-sync", function()
	for _, name in ipairs(WATCHED) do
		forward(name, mp.get_property_native(name))
	end
end)

-- Position ticks are aligned to whole seconds of time-pos: each one fires
-- ~0.1 s after the position crosses the next second. A free-running 1 s timer
-- drifted to an arbitrary phase; near x.98 the ±0.02 s jitter of time-pos made
-- the plugin's floor()ed clock skip a second (0:14 -> 0:16) and later repeat
-- one, and every pause/resume reset the phase and could drop a second.
local PAST_SECOND = 0.1
local ticks = 0
local tick_timer = nil

local function send_tick()
	local pos = mp.get_property_number("time-pos")
	if pos then
		emit({ request_id = 100, data = pos })
	end
	if ticks % 10 == 0 then
		local bitrate = mp.get_property_number("audio-bitrate")
		if bitrate then
			emit({ request_id = 200, data = bitrate })
		end
	end
	ticks = ticks + 1
end

local schedule_tick

local function on_tick()
	tick_timer = nil
	if on_track() then
		send_tick()
	end
	schedule_tick()
end

schedule_tick = function()
	if tick_timer then
		tick_timer:kill()
		tick_timer = nil
	end
	if mp.get_property_bool("pause") then
		return
	end
	local delay = 1
	local pos = mp.get_property_number("time-pos")
	if pos then
		local speed = mp.get_property_number("speed") or 1
		delay = (math.floor(pos) + 1 + PAST_SECOND - pos) / (speed > 0 and speed or 1)
	end
	tick_timer = mp.add_timeout(delay, on_tick)
end

-- On pause, report the exact stop position: a pause landing between a second
-- boundary and its tick would otherwise show the previous second while paused
-- and skip the current one on resume.
mp.observe_property("pause", "bool", function(_, paused)
	if paused and on_track() then
		local pos = mp.get_property_number("time-pos")
		if pos then
			emit({ request_id = 100, data = pos })
		end
	end
	schedule_tick()
end)

-- After a seek or a track start: report the new position at once and re-align.
mp.register_event("playback-restart", function()
	if on_track() and not mp.get_property_bool("pause") then
		local pos = mp.get_property_number("time-pos")
		if pos then
			emit({ request_id = 100, data = pos })
		end
	end
	schedule_tick()
end)

if opts.cache ~= "" and opts.partial ~= "" then
	local started = false
	local done = false

	mp.observe_property("demuxer-cache-state", "native", function(_, st)
		if started or type(st) ~= "table" or not st["bof-cached"] or not st["eof-cached"] then
			return
		end
		-- Only the real track (entry 1 between the two silent dummies), and only
		-- when the cache holds it as one contiguous range.
		if mp.get_property_number("playlist-pos") ~= 1 then
			return
		end
		local ranges = st["seekable-ranges"]
		if type(ranges) ~= "table" or #ranges ~= 1 then
			return
		end
		started = true
		emit({ event = "ytm-cache-started" })
		-- An explicit end makes the dump finish at once; "no" would keep the
		-- file open and appending for as long as mpv runs. +1 s keeps the last
		-- packet, which cache-end alone cuts off.
		local stop = (tonumber(st["cache-end"]) or 0) + 1
		mp.command_native_async({ "dump-cache", 0, stop, opts.partial }, function(ok)
			done = true
			if ok and os.rename(opts.partial, opts.cache) then
				emit({ event = "ytm-cached", path = opts.cache })
			else
				os.remove(opts.partial)
				emit({ event = "ytm-cache-failed" })
			end
		end)
	end)

	mp.register_event("shutdown", function()
		if started and not done then
			os.remove(opts.partial)
		end
	end)
end
