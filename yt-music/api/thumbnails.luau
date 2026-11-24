--!strict

-- thumbnail path/ensure/attach helpers.

local const = require("./constants.luau")
local THUMB_DIR = const.THUMB_DIR

local network = require("../utils/network.luau")

local EXPO = {}

-- Thumbnail filename = stable resource id extracted from the URL itself:
--   yt3.googleusercontent.com/<seg>=w120…          → <seg>
--   lh3.googleusercontent.com/<prefix>/<seg>=s576  → <seg>, when short enough
--   i.ytimg.com/vi/<videoId>/hqdefault.jpg         → <videoId>
-- Identical covers therefore collapse to one file/download with zero hashing
-- or extra machinery. Unrecognised shapes fall back to the legacy per-id name
-- (dedup skipped for those, none observed in practice).
local function thumb_key(url): string?
	if type(url) ~= "string" or url == "" then
		return nil
	end
	local seg1 = url:match("yt3%.googleusercontent%.com/([^/=]+)")
	if seg1 and seg1 ~= "" then
		return seg1
	end
	-- Podcast artwork is the two-segment shape, where the FIRST segment is a
	-- constant ("youtube-podcasts-ingestion-proxy") and the id is the second.
	-- Keying these on the first segment put every show in the library on one
	-- cached file — the first show's cover, drawn for all of them.
	local seg2b = url:match("lh3%.googleusercontent%.com/[^/]+/([^/=]+)")
	if seg2b and seg2b ~= "" then
		-- …but that second segment is an opaque signed reference, 250–300
		-- characters in practice: past the 255-byte filename cap, and it changes
		-- whenever the signature rotates. Neither fits a cache filename, so give
		-- up on it (returning nil, never falling through to the constant first
		-- segment below) and let the caller name the file after the item — one
		-- file per show, stable across rotations.
		if #seg2b > 128 then
			return nil
		end
		return seg2b
	end
	local seg2 = url:match("lh3%.googleusercontent%.com/([^/=]+)")
	if seg2 and seg2 ~= "" then
		return seg2
	end
	local vid = url:match("i%.ytimg%.com/vi/([%w%-_]+)")
	if vid and vid ~= "" then
		return vid
	end
	return nil
end

-- Content-addressed thumbnail path: one file per unique source resource, so
-- album playlists sharing a cover download (and store) it exactly once.
-- Falls back to the legacy per-id name when no key is extractable.
function EXPO.path_for(id: string, url: string?): string
	local key = thumb_key(url)
	if key then
		return THUMB_DIR .. "/" .. key .. ".jpg"
	end
	return THUMB_DIR .. "/" .. id .. ".jpg"
end

local path_for = EXPO.path_for

-- Cover downloads run in-process (noctalia.download) instead of one curl per
-- cover or per batch. At most DL_CONCURRENCY run at once; requests for the
-- same file share one download; failures leave no partial file behind.
local DL_CONCURRENCY = 8
local dl_queue = {}
local dl_active = 0
local dl_waiters: { [string]: { (boolean) -> () } } = {}
local known_thumb_files = {}

local function dl_finish(path: string, ok: boolean)
	if ok and noctalia.fileExists(path) then
		known_thumb_files[path] = true
	else
		ok = false
		if noctalia.fileExists(path) then
			noctalia.removeFile(path)
		end
	end
	local waiters = dl_waiters[path] or {}
	dl_waiters[path] = nil
	for _, cb in ipairs(waiters) do
		cb(ok)
	end
end

local function dl_pump()
	while dl_active < DL_CONCURRENCY and #dl_queue > 0 do
		local job = table.remove(dl_queue, 1)
		dl_active = dl_active + 1
		local accepted = network.download(job.url, job.path, function(ok)
			dl_active = dl_active - 1
			dl_finish(job.path, ok == true)
			dl_pump()
		end)
		if not accepted then
			dl_active = dl_active - 1
			dl_finish(job.path, false)
		end
	end
end

local function fetch_cover(url: string, path: string, cb: (boolean) -> ())
	if dl_waiters[path] then
		table.insert(dl_waiters[path], cb)
		return
	end
	dl_waiters[path] = { cb }
	table.insert(dl_queue, { url = url, path = path })
	noctalia.mkdirAll(THUMB_DIR)
	dl_pump()
end

function EXPO.get_thumbnail_path(id: string, url: string?, callback: ((string) -> ())?): string?
	if type(id) ~= "string" or id == "" then
		return nil
	end
	local path = path_for(id, url)

	if known_thumb_files[path] or noctalia.fileExists(path) then
		return path
	end

	if type(url) == "string" and url ~= "" then
		fetch_cover(url, path, function(ok)
			if ok and callback then
				callback(path)
			end
		end)
	end

	return nil
end

local function preload_thumb_cache()
	noctalia.mkdirAll(THUMB_DIR)
	do
		local _e = noctalia.listDir(THUMB_DIR)
		if type(_e) == "table" then
			for _, _n in ipairs(_e) do
				known_thumb_files[THUMB_DIR .. "/" .. tostring(_n)] = true
			end
		end
	end
end
preload_thumb_cache()

function EXPO.ensure_thumbnails(items, on_updated, tag)
	if type(items) ~= "table" or #items == 0 then
		return
	end

	local missing = {}
	local updated_cached = false

	for _, item in ipairs(items) do
		if type(item) == "table" and type(item.id) == "string" and item.id ~= "" then
			if not item.thumb_path then
				local url = (type(item.thumbnail_url) == "string" and item.thumbnail_url ~= "") and item.thumbnail_url
					or ("https://i.ytimg.com/vi/" .. item.id .. "/hqdefault.jpg")
				local path = path_for(item.id, url)
				if known_thumb_files[path] then
					item.thumb_path = path
					updated_cached = true
				else
					table.insert(missing, { item = item, path = path, url = url })
				end
			end
		end
	end

	if #missing == 0 then
		if updated_cached and type(on_updated) == "function" then
			on_updated()
		end
		return
	end

	-- One download per unique path; a single publish once the batch settles
	-- (each publish copies the whole snapshot into every entry).
	local by_path = {}
	local pending = 0
	for _, m in ipairs(missing) do
		if not by_path[m.path] then
			by_path[m.path] = { url = m.url, items = {} }
			pending = pending + 1
		end
		table.insert(by_path[m.path].items, m.item)
	end
	local attached = updated_cached
	for path, entry in pairs(by_path) do
		fetch_cover(entry.url, path, function(ok)
			if ok then
				for _, item in ipairs(entry.items) do
					item.thumb_path = path
				end
				attached = true
			end
			pending = pending - 1
			if pending == 0 and attached and type(on_updated) == "function" then
				on_updated()
			end
		end)
	end
end

function EXPO.attach_cached_thumbs(items: { { [string]: any } })
	if type(items) ~= "table" then
		return
	end
	local count = #items
	if count > 50 then
		count = 50
	end
	for i = 1, count do
		local item = items[i]
		if type(item) == "table" and type(item.id) == "string" and item.id ~= "" then
			local path = path_for(item.id, item.thumbnail_url)
			if known_thumb_files[path] == nil then
				known_thumb_files[path] = noctalia.fileExists(path)
			end
			if known_thumb_files[path] then
				item.thumb_path = path
			end
		end
	end
end

function EXPO.reset_thumb_cache()
	known_thumb_files = {}
end

return EXPO
