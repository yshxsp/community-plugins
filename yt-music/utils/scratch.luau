-- Shared scratch-file slots under the private runtime dir.
-- One mkdir at load, then a small rotating pool of reusable names: concurrent
-- requests get distinct slots, the next caller overwrites, nothing accumulates.

local Scratch = {}
-- Private per-user runtime dir (tmpfs, 0700), shared with scripts/mpv.sh.
local RUNTIME = noctalia.getenv("XDG_RUNTIME_DIR")
Scratch.DIR = ((RUNTIME and RUNTIME ~= "") and RUNTIME or "/tmp") .. "/yt-music"

noctalia.mkdirAll(Scratch.DIR)

local counter = 0
local SLOTS = 128

function Scratch.path(prefix)
	counter = counter + 1
	return Scratch.DIR .. "/" .. prefix .. "-" .. ((counter % SLOTS) + 1)
end

return Scratch
