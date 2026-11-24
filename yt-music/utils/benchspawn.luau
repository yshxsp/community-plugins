-- Bench instrumentation: when ~/.cache/yt-music/bench-spawns exists at entry
-- load, every process launch and HTTP request made through the noctalia API is
-- appended to ~/.cache/yt-music/bench-spawns.log as
--   <nowMs>\t<entry>\t<kind>\t<command>
-- Off (a single fileExists at load) unless the flag file is present.

local FLAG = "~/.cache/yt-music/bench-spawns"
local LOG = "~/.cache/yt-music/bench-spawns.log"

local function install(entry: string)
	if not noctalia.fileExists(FLAG) then
		return
	end
	local function record(kind: string, what: any)
		local text
		if type(what) == "table" then
			text = table.concat(what, " ")
		else
			text = tostring(what)
		end
		text = text:gsub("[\r\n\t]+", " ")
		local prev = noctalia.readFile(LOG) or ""
		noctalia.writeFile(LOG, prev .. ("%d\t%s\t%s\t%s\n"):format(noctalia.nowMs(), entry, kind, text:sub(1, 160)))
	end
	local orig_async = noctalia.runAsync
	noctalia.runAsync = function(cmd, ...)
		record("runAsync", cmd)
		return orig_async(cmd, ...)
	end
	local orig_stream = noctalia.runStream
	noctalia.runStream = function(cmd, ...)
		record("runStream", cmd)
		return orig_stream(cmd, ...)
	end
	local orig_http = noctalia.http
	noctalia.http = function(req, ...)
		record("http", type(req) == "table" and req.url or req)
		return orig_http(req, ...)
	end
	local orig_dl = noctalia.download
	if orig_dl then
		noctalia.download = function(url, ...)
			record("download", url)
			return orig_dl(url, ...)
		end
	end
end

return install
