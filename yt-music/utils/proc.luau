-- Single choke point for every process launch and HTTP request the plugin
-- makes. With ~/.cache/yt-music/bench-spawns present at load, each call is
-- appended to ~/.cache/yt-music/bench-spawns.log as
--   <nowMs>\t<kind>\t<command>
-- for measurement; otherwise the wrappers are plain pass-throughs.

local FLAG = "~/.cache/yt-music/bench-spawns"
local LOG = "~/.cache/yt-music/bench-spawns.log"

local Proc = {}

local bench = noctalia.fileExists(FLAG)

local function record(kind, what)
	local text = type(what) == "table" and table.concat(what, " ") or tostring(what)
	text = text:gsub("[\r\n\t]+", " ")
	local prev = noctalia.readFile(LOG) or ""
	noctalia.writeFile(LOG, prev .. ("%d\t%s\t%s\n"):format(noctalia.nowMs(), kind, text:sub(1, 200)))
end

function Proc.runAsync(cmd, ...)
	if bench then
		record("runAsync", cmd)
	end
	return noctalia.runAsync(cmd, ...)
end

function Proc.runStream(cmd, ...)
	if bench then
		record("runStream", cmd)
	end
	return noctalia.runStream(cmd, ...)
end

function Proc.http(req, ...)
	if bench then
		record("http", type(req) == "table" and req.url or req)
	end
	return noctalia.http(req, ...)
end

function Proc.download(url, ...)
	if bench then
		record("download", url)
	end
	return noctalia.download(url, ...)
end

return Proc
