local Mpv = {}
local Bash = require("../utils/bash.luau")
local proc = require("../utils/proc.luau")
local scratch = require("../utils/scratch.luau")
local store = require("./store.luau")
local logger = require("../utils/log.luau")
local log = logger.module("ytm", "mpv")

-- Same private runtime dir scripts/mpv.sh uses.
Mpv.SOCK = scratch.DIR .. "/mpv.sock"

-- ncat closes the connection on stdin EOF unless told not to; OpenBSD nc
-- keeps reading the socket but needs -N to exit after a one-shot send. The
-- boot health check records which one is installed.
local function is_ncat()
	local nc = type(store.state.health) == "table" and store.state.health.nc
	return type(nc) == "table" and nc.detail == "ncat"
end

-- One process per command: sh feeds the JSON line from a here-document and
-- execs nc, so nothing else is forked. The payload is passed as $2 and is not
-- re-expanded inside the here-document.
function Mpv.send(payload_json)
	if not noctalia.fileExists(Mpv.SOCK) then
		return
	end
	local flags = is_ncat() and "-U -w1" or "-N -U -w1"
	proc.runAsync({
		"sh",
		"-c",
		"exec nc " .. flags .. ' "$1" <<EOF\n$2\nEOF',
		"sh",
		Mpv.SOCK,
		payload_json,
	}, function() end, 5000)
end

-- url/title go through per-call scratch slots (rotating pool, overwritten on
-- reuse) so a fast track switch can never clobber the previous launch inputs.
-- cache_path/partial_path ask ytm.lua to save the track from mpv's cache.
function Mpv.play(url, title, volume, on_ready, cover_path, cache_path, partial_path)
	local url_file = scratch.path("mpv-url")
	local title_file = scratch.path("mpv-title")
	noctalia.writeFile(url_file, url)
	noctalia.writeFile(title_file, title or "")
	Bash.run_script(
		"mpv.sh",
		"mpv_play",
		function(res)
			local out = (type(res) == "table" and res.stdout) or ""
			local ready = out:find("READY=1", 1, true) ~= nil
			local ms = out:match("MS=(%d+)")
			log("mpv_play ready=" .. tostring(ready) .. (ms and (" in " .. ms .. "ms") or ""))
			if type(on_ready) == "function" then
				on_ready(ready)
			end
		end,
		10000,
		tostring(volume or 100),
		url_file,
		title_file,
		cover_path or "",
		cache_path or "",
		partial_path or ""
	)
end

function Mpv.kill()
	Bash.run_script("mpv.sh", "mpv_kill", function() end, 2000)
end

-- Event stream for one mpv instance: a single nc holding the IPC connection.
-- It asks ytm.lua for a full state sync, then just relays the events ytm.lua
-- pushes; it exits on its own when mpv dies and the socket closes.
function Mpv.stream(on_line)
	local keep_open = is_ncat() and "--no-shutdown -U" or "-U"
	local cmd = "exec nc "
		.. keep_open
		.. " "
		.. Bash.sh_quote(Mpv.SOCK)
		.. " <<'EOF'\n"
		.. '{"command":["script-message","ytm-sync"]}\n'
		.. "EOF"
	return proc.runStream(cmd, on_line)
end

return Mpv
