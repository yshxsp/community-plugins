--!strict
local timer = require("../utils/timer.luau")
local proc = require("../utils/proc.luau")

-- stream resolution, audio download/cache, track stats, prefetch.

local logger = require("../utils/log.luau")
local log = logger.module("ytapi", "resolve")

local const = require("./constants.luau")
local COOKIE_PATH = const.COOKIE_PATH
local STREAMS_CACHE_DIR = const.STREAMS_CACHE_DIR
local AUDIO_DIR = const.AUDIO_DIR

local thumbs = require("./thumbnails.luau")
local get_thumbnail_path = thumbs.get_thumbnail_path

local types = require("../utils/types.luau")
local stats = require("./stats.luau")
local network = require("../utils/network.luau")

-- Fast tiers (the "last client that worked" idea from ArchiveTune), tried in
-- order before yt-dlp's default clients (~4.5 s per resolve, mostly
-- sequential requests). Measured 2026-11-26, all returning the same Opus 251:
--   1. visionos, no cookies: ~1.4 s, no JS challenge, and no preroll ad. With
--      cookies (tv_samsung, default clients) most tracks carry a 6 s ad and
--      googlevideo answers 403 until ~4 s after the URL is minted; visionos
--      URLs serve the whole file at once. It needs the watch page's visitor
--      data (without it: "confirm you're not a bot").
--   2. tv_samsung with cookies: ~1.9 s plus the ad wait. No watch page, no
--      configs, no initial data (the ~1 s watch-next request).
-- Both use a www URL (a music URL adds a web_music player request); views
-- and likes come from api/stats.luau in-process. A tier's result is accepted
-- only when it is audio-only. On a miss the next tier runs at once and the
-- failed tier rests for FAST_BACKOFF_S, unless the miss is about the video
-- itself (age gate, private, members-only), which says nothing about the
-- client. Quality holds even when YouTube changes a client.
local FAST_TIERS = {
	{ name = "visionos", args = "youtube:player_client=visionos;player_skip=configs,initial_data", cookies = false },
	{
		name = "tv_samsung",
		args = "youtube:player_client=tv_samsung;player_skip=webpage,configs,initial_data",
		cookies = true,
	},
}
local DEFAULT_TIER = #FAST_TIERS + 1
local FAST_BACKOFF_S = 10 * 60
local tier_disabled_until: { [number]: number } = {}
local VIDEO_SPECIFIC_ERRORS = { "confirm your age", "Private video", "members-only", "Join this channel" }

local function first_tier(from: number): number
	local now = os.time()
	for i = from, #FAST_TIERS do
		if now >= (tier_disabled_until[i] or 0) then
			return i
		end
	end
	return DEFAULT_TIER
end

local function build_resolve_argv(safe_id: string, tier: number): { string }
	-- yt-dlp's own client selection: the old forced mweb,web clients now
	-- return only format 18 (a 360p video with AAC audio), never audio-only.
	-- One extraction yields the stream URL (last line) plus view/like counts,
	-- duration and the chosen format, so playback never needs a second yt-dlp
	-- run for stats.
	local argv = {
		"yt-dlp",
		"-f",
		"bestaudio/best",
		"-g",
		"--print",
		"STATS=%(view_count)s|%(like_count)s|%(duration)s",
		"--print",
		"FMT=%(format_id)s|%(acodec)s|%(vcodec)s",
		"--no-playlist",
		"--no-warnings",
	}
	local fast = FAST_TIERS[tier]
	if fast then
		table.insert(argv, "--extractor-args")
		table.insert(argv, fast.args)
	end
	if (not fast or fast.cookies) and noctalia.fileExists(COOKIE_PATH) then
		table.insert(argv, "--cookies")
		table.insert(argv, COOKIE_PATH)
	end
	local host = fast and "https://www.youtube.com" or "https://music.youtube.com"
	table.insert(argv, host .. "/watch?v=" .. safe_id)
	return argv
end

local function sanitize_str(str)
	if type(str) ~= "string" then
		return ""
	end
	return (str:gsub("[^\32-\126]", ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local EXPO = {}

local stream_cache = {}
-- Track length in seconds from the last resolve, for callers that must know
-- whether mpv's cache can hold the whole file.
local stream_durations: { [string]: number? } = {}

function EXPO.stream_duration(video_id: string): number?
	return stream_durations[video_id]
end
local resolving_in_flight = {}
local attempt_resolve: (string, number, number?) -> () -- forward: resolve_stream parks the list, attempt spawns
local STREAM_DISK_TTL = 4 * 3600

function EXPO.get_audio_cache_path(video_id: string): string?
	if type(video_id) ~= "string" or video_id == "" then
		return nil
	end
	local safe_id = video_id:gsub("[^%w%-_]", "_")
	local path = AUDIO_DIR .. "/" .. safe_id .. ".opus"
	if noctalia.fileExists(path) then
		return path
	end
	return nil
end

-- Final and in-progress paths for an mpv cache dump. The partial lives in a
-- dot-directory so the .opus scan of AUDIO_DIR never sees half-written files.
function EXPO.audio_cache_paths(video_id: string): (string, string)
	local safe_id = video_id:gsub("[^%w%-_]", "_")
	noctalia.mkdirAll(AUDIO_DIR .. "/.partial")
	return AUDIO_DIR .. "/" .. safe_id .. ".opus", AUDIO_DIR .. "/.partial/" .. safe_id .. ".opus"
end

function EXPO.get_cached_audio_ids(callback)
	noctalia.mkdirAll(AUDIO_DIR)
	local set = {}
	local entries = noctalia.listDir(AUDIO_DIR)
	if type(entries) == "table" then
		for _, name in ipairs(entries) do
			local id = tostring(name):match("([%w%-_]+)%.opus$")
			if id then
				set[id] = true
			end
		end
	end
	if callback then
		callback(set)
	end
end

function EXPO.cache_audio(video_id, callback)
	if type(video_id) ~= "string" or video_id == "" then
		if callback then
			callback(false)
		end
		return
	end
	local safe_id = video_id:gsub("[^%w%-_]", "_")
	local path = AUDIO_DIR .. "/" .. safe_id .. ".opus"
	if noctalia.fileExists(path) then
		if callback then
			callback(true)
		end
		return
	end

	noctalia.mkdirAll(AUDIO_DIR)
	local argv = { "yt-dlp", "-f", "bestaudio/best", "-o", path }
	if noctalia.fileExists(COOKIE_PATH) then
		table.insert(argv, "--cookies")
		table.insert(argv, COOKIE_PATH)
	end
	table.insert(argv, "https://music.youtube.com/watch?v=" .. safe_id)

	local launched = network.runAsync(argv, function(res)
		local ok = noctalia.fileExists(path)
		if not ok and type(res) == "table" then
			ok = res.exitCode == 0
		end
		if callback then
			callback(ok)
		end
	end, 120000)
	if not launched and callback then
		callback(false)
	end
end

function EXPO.resolve_stream(video_id: string, cb: ((string?) -> ())?)
	if type(video_id) ~= "string" or video_id == "" then
		if cb then
			cb(nil)
		end
		return
	end

	local local_audio = EXPO.get_audio_cache_path(video_id)
	if local_audio then
		log("audio_disk_cache HIT for id=" .. video_id)
		if cb then
			cb(local_audio)
		end
		return
	end

	local cached = stream_cache[video_id]
	if cached and (os.time() - cached.timestamp) < 14400 then
		log("stream_cache HIT for id=" .. video_id)
		if cb then
			cb(cached.url)
		end
		return
	end

	local safe_id = video_id:gsub("[^%w%-_]", "_")
	local disk_url_path = STREAMS_CACHE_DIR .. "/" .. safe_id .. ".url"
	local info = noctalia.fileInfo(disk_url_path)
	local disk_fresh = false
	if info then
		local mtime_s = info.mtime
		if mtime_s > 1e11 then
			mtime_s = mtime_s / 1000
		end
		disk_fresh = (os.time() - mtime_s) < STREAM_DISK_TTL
		if not disk_fresh then
			log("stream_disk_cache STALE for id=" .. video_id)
			noctalia.removeFile(disk_url_path)
		end
	end
	if disk_fresh then
		local raw_disk = noctalia.readFile(disk_url_path)
		if raw_disk and #raw_disk > 20 then
			local clean_url = sanitize_str(raw_disk)
			stream_cache[video_id] = { url = clean_url, timestamp = os.time() }
			log("stream_disk_cache HIT for id=" .. video_id)
			if cb then
				cb(clean_url)
			end
			return
		end
	end

	if resolving_in_flight[video_id] then
		table.insert(resolving_in_flight[video_id], cb)
		return
	end

	resolving_in_flight[video_id] = { cb }
	attempt_resolve(video_id, 0)
end

-- Spawn the yt-dlp fetch for a video_id whose callback list is already parked
-- in resolving_in_flight. Attempt 0 is the first try; on host spawn refusal
-- (burst saturation from rapid skips) one delayed retry follows, then fail.
attempt_resolve = function(video_id, attempt, tier)
	tier = tier or first_tier(1)
	local fast = FAST_TIERS[tier]
	local safe_id = video_id:gsub("[^%w%-_]", "_")
	log("resolving stream URL for id=" .. video_id .. (fast and (" (fast path: " .. fast.name .. ")") or ""))
	local argv = build_resolve_argv(safe_id, tier)
	local started_ms = noctalia.nowMs()
	local launched = network.runAsync(argv, function(res)
		local elapsed_ms = noctalia.nowMs() - started_ms
		local out = type(res) == "table" and res.stdout or ""
		local raw_url = out:match("([^\n\r]+)%s*$")
		local url = sanitize_str(raw_url)
		if url:sub(1, 4) ~= "http" then
			url = ""
		end

		if fast then
			local _fid, acodec, vcodec = out:match("FMT=([^|\n]*)|([^|\n]*)|([^|\n]*)")
			local audio_only = acodec and acodec ~= "none" and vcodec == "none"
			local offline = out:find("NETGATE=OFFLINE", 1, true) ~= nil
			local timed_out = type(res) == "table" and res.timedOut
			local reaped = type(res) == "table" and (res.exitCode == 143 or res.exitCode == 137)
			if not (url ~= "" and audio_only) and not offline and not timed_out and not reaped then
				local err = type(res) == "table" and res.stderr or ""
				local video_specific = false
				for _, needle in ipairs(VIDEO_SPECIFIC_ERRORS) do
					if err:find(needle, 1, true) then
						video_specific = true
						break
					end
				end
				if not video_specific then
					tier_disabled_until[tier] = os.time() + FAST_BACKOFF_S
				end
				local next_tier = first_tier(tier + 1)
				log(
					"fast path "
						.. fast.name
						.. " rejected for id="
						.. video_id
						.. " (format "
						.. tostring(_fid)
						.. " "
						.. tostring(acodec)
						.. "/"
						.. tostring(vcodec)
						.. ", "
						.. elapsed_ms
						.. "ms"
						.. (video_specific and ", video-specific" or (", tier off for " .. FAST_BACKOFF_S .. " s"))
						.. "); next: "
						.. (FAST_TIERS[next_tier] and FAST_TIERS[next_tier].name or "default clients")
				)
				if resolving_in_flight[video_id] then
					attempt_resolve(video_id, attempt, next_tier)
				end
				return
			end
		end

		local callbacks = resolving_in_flight[video_id] or {}
		resolving_in_flight[video_id] = nil

		-- The fast path prints NA for views/likes (no initial data); the
		-- player then gets them from stats.track_stats.
		local views, likes, duration = out:match("STATS=([%w]*)|([%w]*)|([%w%.]*)")
		if tonumber(views) and tonumber(likes) then
			stats.store_stats(video_id, tonumber(views) :: number, tonumber(likes) :: number)
		end
		if tonumber(duration) then
			stream_durations[video_id] = tonumber(duration)
		end
		if url ~= "" then
			log("stream resolved successfully (" .. #url .. " bytes, " .. elapsed_ms .. "ms) for id=" .. video_id)
			stream_cache[video_id] = { url = url, timestamp = os.time() }
			noctalia.mkdirAll(STREAMS_CACHE_DIR)
			noctalia.writeFile(STREAMS_CACHE_DIR .. "/" .. safe_id .. ".url", url)
			for _, callback in ipairs(callbacks) do
				if callback then
					callback(url)
				end
			end
		else
			local reason = "failed"
			if out:find("NETGATE=OFFLINE", 1, true) then
				reason = "offline, deferred"
			elseif type(res) == "table" and res.timedOut then
				reason = "timed out"
			elseif type(res) == "table" and (res.exitCode == 143 or res.exitCode == 137) then
				-- SIGTERM/SIGKILL is our own supersede kill reaping a stale
				-- fetch during rapid skips — expected, not an error.
				reason = "superseded (stale fetch reaped)"
			end
			log("stream resolution " .. reason .. " (" .. elapsed_ms .. "ms) for id=" .. video_id)
			if reason == "failed" or reason == "timed out" then
				network.reportFailure()
			end
			for _, callback in ipairs(callbacks) do
				if callback then
					callback(nil)
				end
			end
		end
	end, 30000)
	if not launched then
		-- Host refused the spawn: rapid skips fill every slot with stale
		-- yt-dlp fetches, so the final song's resolve is the one refused and
		-- its entry would wedge (UI loading forever + id poisoned). Retry once
		-- after the burst drains; if that also fails, fail fast with nil so
		-- the owner falls back to stopped instead of hanging. (Offline is not
		-- a refusal: the net gate schedules a synthetic failure instead.)
		if attempt < 1 then
			log("stream resolve launch refused for id=" .. video_id .. ", retrying")
			local scheduled = timer.after(1500, function()
				if resolving_in_flight[video_id] then
					attempt_resolve(video_id, attempt + 1, tier)
				end
			end)
			if scheduled then
				return
			end
		end
		log("stream resolve launch refused for id=" .. video_id)
		local pending = resolving_in_flight[video_id] or {}
		resolving_in_flight[video_id] = nil
		for _, callback in ipairs(pending) do
			if callback then
				callback(nil)
			end
		end
	end
end

function EXPO.prefetch_track(item: types.Track)
	if type(item) ~= "table" or not item.id or item.id == "" then
		return
	end
	-- Prefetching is pure network work; skip entirely when offline.
	if not network.isOnline() then
		return
	end
	local id = item.id

	if item.thumbnail_url or id ~= "" then
		local url = item.thumbnail_url or ("https://i.ytimg.com/vi/" .. id .. "/hqdefault.jpg")
		get_thumbnail_path(id, url, nil)
	end

	if EXPO.get_audio_cache_path(id) then
		return
	end

	local cached = stream_cache[id]
	if not cached or (os.time() - cached.timestamp) >= 7200 then
		log("prefetching stream URL into memory for id=" .. id)
		EXPO.resolve_stream(id, nil)
	end
end

function EXPO.prefetch_queue(queue: { types.Track }, current_index)
	if type(queue) ~= "table" or #queue == 0 then
		return
	end
	current_index = current_index or 1
	-- Only prefetch 1 track ahead to prevent thread pool exhaustion and UI freezing
	for offset = 1, 1 do
		local target = queue[current_index + offset]
		if target and target.id and target.id ~= "" then
			EXPO.prefetch_track(target)
		end
	end
end

return EXPO
