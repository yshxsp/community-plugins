local timer = require("./timer.luau")
local proc = require("./proc.luau")
-- Global network gate ("middleware"): every outbound-capable launch goes
-- through here. When offline, calls are refused BEFORE spawning and callers
-- receive a synthetic failed result, so pending flags/spinners always settle.

local Net = {}

local online = true

function Net.isOnline()
	return online
end

function Net.setOnline(v)
	online = v and true or false
end

local function synthetic_result()
	return {
		exitCode = 1,
		stdout = "NETGATE=OFFLINE\n",
		stderr = "",
		timedOut = false,
		stdoutTruncated = false,
		stderrTruncated = false,
	}
end

-- Drop-in for noctalia.runAsync for anything that may touch the network.
-- Local-only work (mpv IPC, disk scans) must NOT use this.
--
-- Contract for runAsync/http/download: the return value is false only when
-- cb will never run (the host refused the request). Offline, cb still runs
-- (deferred) with a failure result and the call returns true, so callers
-- never complete the same request twice.
function Net.runAsync(cmd, cb, timeout, tag)
	if not online then
		if cb then
			timer.defer(function()
				cb(synthetic_result())
			end)
		end
		return true
	end
	return proc.runAsync(cmd, cb, timeout)
end

-- Connectivity is assumed while requests succeed; the first transport
-- failure (no HTTP status at all) wakes the service, which then probes until
-- the network is back. No periodic probing while online.
local failure_hook = nil

function Net.onFailure(fn)
	failure_hook = fn
end

function Net.reportFailure()
	if failure_hook then
		failure_hook()
	end
end

-- Drop-in for noctalia.http; offline delivers a failed response object.
function Net.http(req, cb)
	if not online then
		timer.defer(function()
			cb({ ok = false, status = 0, body = "" })
		end)
		return true
	end
	return proc.http(req, function(resp)
		if type(resp) ~= "table" or (not resp.ok and (tonumber(resp.status) or 0) == 0) then
			Net.reportFailure()
		end
		cb(resp)
	end)
end

-- In-process download to a file; offline answers cb(false) without trying.
function Net.download(url, dest, cb)
	if not online then
		timer.defer(function()
			cb(false)
		end)
		return true
	end
	return proc.download(url, dest, cb)
end

-- One in-process request (no curl): true when YouTube Music answers at all.
function Net.probe(cb)
	local accepted = proc.http({ url = "https://music.youtube.com/generate_204" }, function(resp)
		cb(type(resp) == "table" and (tonumber(resp.status) or 0) > 0)
	end)
	if not accepted then
		cb(false)
	end
end

return Net
