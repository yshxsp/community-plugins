--!strict

-- Track stats (views/likes) fetched via yt-dlp, cached in a single JSON file.

local logger = require("../utils/log.luau")
local network = require("../utils/network.luau")
local log = logger.module("ytapi", "stats")

local const = require("./constants.luau")
local STATS_CACHE_PATH = const.STATS_CACHE_PATH

-- Counts are refreshed by every stream resolve (same yt-dlp run), so a stale
-- entry is still served as-is: it only matters for tracks played from the
-- offline cache, where a fresh yt-dlp run (~1.7 s CPU) just for two numbers
-- is not worth it. Entries are kept for 30 days.
local STATS_KEEP = 30 * 24 * 3600

local EXPO = {}

local stats_cache = {}
local stats_in_flight = {}
local cache_loaded = false

local function load_cache()
	if cache_loaded then
		return
	end
	cache_loaded = true
	if not noctalia.fileExists(STATS_CACHE_PATH) then
		return
	end
	local raw = noctalia.readFile(STATS_CACHE_PATH)
	local data = raw and noctalia.json.decode(raw)
	if type(data) ~= "table" then
		return
	end
	for id, entry in pairs(data) do
		if type(id) == "string" and type(entry) == "table" then
			stats_cache[id] = {
				views = tonumber(entry.views) or 0,
				likes = tonumber(entry.likes) or 0,
				timestamp = tonumber(entry.fetched) or 0,
			}
		end
	end
end

local function save_cache()
	local data = {}
	local now = os.time()
	for id, entry in pairs(stats_cache) do
		if (now - entry.timestamp) < STATS_KEEP then
			data[id] = { views = entry.views, likes = entry.likes, fetched = entry.timestamp }
		else
			stats_cache[id] = nil
		end
	end
	local encoded = noctalia.json.encode(data)
	if encoded then
		noctalia.writeFile(STATS_CACHE_PATH, encoded)
	end
end

-- Filled by the stream resolve, which prints the counts in the same yt-dlp
-- run, so track_stats normally answers from cache without spawning.
function EXPO.store_stats(video_id: string, views: number, likes: number)
	load_cache()
	stats_cache[video_id] = { views = views, likes = likes, timestamp = os.time() }
	save_cache()
end

local WEB_CLIENT_VERSION = "2.20260708.05.00"
local VIEWS_ANCHOR = '"videoViewCountRenderer":{"viewCount":{"simpleText":"'
local LIKES_ANCHOR = "along with "

local function count_after(raw: string, anchor: string, pattern: string): number?
	local from = 1
	for _ = 1, 5 do
		local at = raw:find(anchor, from, true)
		if not at then
			return nil
		end
		local digits = raw:sub(at, at + #anchor + 40):match(pattern)
		if digits then
			return tonumber((digits:gsub(",", "")))
		end
		from = at + #anchor
	end
	return nil
end

-- Views and likes from a WEB watch-next response (hl=en).
local function parse_counts(raw: string): (number?, number?)
	if raw == "" then
		return nil, nil
	end
	local views = count_after(raw, VIEWS_ANCHOR, '^' .. VIEWS_ANCHOR:gsub("[%p]", "%%%0") .. "([%d,]+) view")
	local likes = count_after(raw, LIKES_ANCHOR, "^along with ([%d,]+) other people")
	return views, likes
end

function EXPO.track_stats(video_id: string, cb: ((number, number) -> ())?)
	if type(video_id) ~= "string" or video_id == "" then
		if cb then
			cb(0, 0)
		end
		return
	end

	load_cache()

	local cached = stats_cache[video_id]
	if cached then
		if cb then
			cb(cached.views, cached.likes)
		end
		return
	end

	if stats_in_flight[video_id] then
		table.insert(stats_in_flight[video_id], cb)
		return
	end
	stats_in_flight[video_id] = { cb }

	-- One in-process request instead of a yt-dlp run (~1.7 s CPU): the
	-- watch-next response of the WEB client carries both counts as text, so
	-- two plain finds read them without decoding ~400 KB of JSON. No cookies
	-- needed. A failed request is not cached, so the counts are asked for
	-- again on the next play.
	local function finish(views: number, likes: number, ok: boolean)
		if ok then
			stats_cache[video_id] = { views = views, likes = likes, timestamp = os.time() }
			save_cache()
		end
		local callbacks = stats_in_flight[video_id] or {}
		stats_in_flight[video_id] = nil
		for _, callback in ipairs(callbacks) do
			if callback then
				callback(views, likes)
			end
		end
	end

	local body = noctalia.json.encode({
		context = { client = { clientName = "WEB", clientVersion = WEB_CLIENT_VERSION, hl = "en" } },
		videoId = video_id,
	})
	local accepted = network.http({
		url = "https://www.youtube.com/youtubei/v1/next?prettyPrint=false",
		method = "POST",
		body = body,
		headers = { "Content-Type: application/json", "Origin: https://www.youtube.com", "User-Agent: Mozilla/5.0" },
	}, function(resp)
		local raw = type(resp) == "table" and resp.ok and resp.body or ""
		local views, likes = parse_counts(raw)
		local ok = views ~= nil or likes ~= nil
		log("stats fetched for id=" .. video_id .. " views=" .. tostring(views) .. " likes=" .. tostring(likes))
		finish(views or 0, likes or 0, ok)
	end)
	if not accepted then
		finish(0, 0, false)
	end
end

return EXPO
