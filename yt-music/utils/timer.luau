-- In-process timers for one entry runtime, driven by that entry's update().
-- The Luau API has no setTimeout; the plugin used to spawn `sleep N` / `true`
-- processes just to get a callback later. Here pending timers set the entry's
-- update interval to the time until the next deadline, and an hourly no-op
-- interval otherwise, so an idle entry is never woken.
--
-- Every entry that requires this module must call Timer.tick() from update().

local Timer = {}

local IDLE_MS = 3600 * 1000
local MIN_MS = 16

local queue = {}
local current_interval = nil

local function reschedule()
	local next_at = nil
	for _, t in ipairs(queue) do
		if not next_at or t.at < next_at then
			next_at = t.at
		end
	end
	local interval = IDLE_MS
	if next_at then
		interval = math.max(MIN_MS, math.floor(next_at - noctalia.nowMs()))
	end
	if interval ~= current_interval then
		current_interval = interval
		noctalia.setUpdateInterval(interval)
	end
end

-- Runs fn once, ms milliseconds from now (at least one update tick later).
function Timer.after(ms: number, fn: () -> ()): boolean
	table.insert(queue, { at = noctalia.nowMs() + math.max(0, ms), fn = fn })
	reschedule()
	return true
end

-- Runs fn on the next tick: breaks up long call chains like the old
-- runAsync("true", fn) did, without a process.
function Timer.defer(fn: () -> ()): boolean
	return Timer.after(0, fn)
end

function Timer.tick()
	if #queue == 0 then
		reschedule()
		return
	end
	local now = noctalia.nowMs()
	local due, rest = {}, {}
	for _, t in ipairs(queue) do
		if t.at <= now then
			table.insert(due, t)
		else
			table.insert(rest, t)
		end
	end
	queue = rest
	table.sort(due, function(a, b)
		return a.at < b.at
	end)
	for _, t in ipairs(due) do
		local ok, err = pcall(t.fn)
		if not ok then
			print("[ytm/timer] callback failed: " .. tostring(err))
		end
	end
	-- Interval set by reschedule() inside callbacks may be stale after the
	-- batch; recompute from what is left.
	current_interval = nil
	reschedule()
end

return Timer
