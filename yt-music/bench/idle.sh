#!/usr/bin/env bash
# Measure system-wide process spawns and noctalia CPU (self + reaped children)
# over a window. Run once with the plugin disabled and once enabled; the
# difference is the plugin's idle cost.
# Usage: bench/idle.sh [seconds]
set -euo pipefail

win="${1:-120}"
pid=$(pgrep -xo noctalia)
hz=$(getconf CLK_TCK)

forks() { awk '/^processes/ {print $2}' /proc/stat; }
# utime stime cutime cstime (fields 14-17); comm may contain spaces, so cut
# after the closing paren.
cpu_ticks() { sed 's/.*) //' "/proc/$pid/stat" | awk '{print $12 + $13 + $14 + $15}'; }

f0=$(forks); c0=$(cpu_ticks)
sleep "$win"
f1=$(forks); c1=$(cpu_ticks)

df=$((f1 - f0))
dc_ms=$(( (c1 - c0) * 1000 / hz ))
awk -v w="$win" -v f="$df" -v c="$dc_ms" 'BEGIN {
  printf "window=%ss forks=%d (%.1f/min) noctalia_cpu=%dms (%.1f ms/min)\n", w, f, f * 60 / w, c, c * 60 / w
}'
