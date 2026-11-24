#!/usr/bin/env bash
# Measure the plugin while something plays: noctalia CPU (self, reaped
# children), mpv CPU, the mpv.sh stream helper's CPU, and the plugin's own
# launches from bench-spawns.log.
# Usage: bench/play.sh [seconds]
set -euo pipefail

win="${1:-120}"
hz=$(getconf CLK_TCK)
log="$HOME/.cache/yt-music/bench-spawns.log"
noc=$(pgrep -xo noctalia)

self_ticks() { sed 's/.*) //' "/proc/$1/stat" | awk '{print $12 + $13}'; }
child_ticks() { sed 's/.*) //' "/proc/$1/stat" | awk '{print $14 + $15}'; }
# Sum of self+children ticks for every live process matching a pattern.
tree_ticks() {
  local total=0 p
  for p in $(pgrep -f "$1"); do
    [ -r "/proc/$p/stat" ] || continue
    total=$((total + $(sed 's/.*) //' "/proc/$p/stat" | awk '{print $12 + $13 + $14 + $15}')))
  done
  echo "$total"
}
forks() { awk '/^processes/ {print $2}' /proc/stat; }

: > "$log"
s0=$(self_ticks "$noc"); c0=$(child_ticks "$noc")
m0=$(tree_ticks 'input-ipc-server=.*mpv[.]sock'); h0=$(tree_ticks 'mpv[.]sh.*mpv_stream')
f0=$(forks)
sleep "$win"
s1=$(self_ticks "$noc"); c1=$(child_ticks "$noc")
m1=$(tree_ticks 'input-ipc-server=.*mpv[.]sock'); h1=$(tree_ticks 'mpv[.]sh.*mpv_stream')
f1=$(forks)

ms() { echo $(( ($1) * 1000 / hz )); }
echo "window=${win}s"
echo "noctalia self   : $(ms $((s1 - s0))) ms"
echo "noctalia reaped : $(ms $((c1 - c0))) ms"
echo "mpv             : $(ms $((m1 - m0))) ms"
echo "stream helper   : $(ms $((h1 - h0))) ms (live bash, excludes its reaped forks)"
echo "system forks    : $((f1 - f0))"
echo "plugin launches :"
cut -f2,3 "$log" | cut -c1-100 | sort | uniq -c | sort -rn
