#!/usr/bin/env bash
# A/B benchmark of plugin revisions on the live shell.
# For each git revision: check it out, reset caches, reload the plugin, then
#   idle    - plugin loaded, nothing playing, panels never opened
#   play    - queue playing, both panels opened once and closed again
#   mini    - queue playing, mini panel open
# Each window reports noctalia CPU (self / reaped children), mpv CPU and the
# plugin's own launches (bench-spawns.log).
# Usage: cp bench/compare.sh /tmp/x.sh; PLUGIN_DIR=$PWD /tmp/x.sh <seconds> <rev>...
set -euo pipefail

win="$1"; shift
# Run a copy from outside the plugin dir: checkouts replace this file mid-run.
dir="${PLUGIN_DIR:-$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)}"
id="yshxsp/yt-music"
cache="$HOME/.cache/yt-music"
queue="$cache/bench-queue.json"
hz=$(getconf CLK_TCK)
noc=$(pgrep -xo noctalia)
orig_rev=$(git -C "$dir" rev-parse --abbrev-ref HEAD)

ticks() { sed 's/.*) //' "/proc/$1/stat" | awk -v f="$2" '{ if (f == "self") print $12 + $13; else print $14 + $15 }'; }
mpv_ticks() {
  local total=0 p
  for p in $(pgrep -f 'input-ipc-server=.*yt-music/mpv[.]sock'); do
    [ -r "/proc/$p/stat" ] && total=$((total + $(sed 's/.*) //' "/proc/$p/stat" | awk '{print $12 + $13}')))
  done
  echo "$total"
}
mpv_rss_kb() {
  local p
  p=$(pgrep -f 'input-ipc-server=.*yt-music/mpv[.]sock' | head -1)
  [ -n "$p" ] && awk '/^VmRSS/ {print $2}' "/proc/$p/status" || echo 0
}
mpv_alive() { pgrep -f 'input-ipc-server=.*yt-music/mpv[.]sock' >/dev/null; }
msg() { noctalia msg "$@" >/dev/null; }

measure() {   # $1=label
  : > "$cache/bench-spawns.log"
  local s0 c0 m0 s1 c1 m1
  s0=$(ticks "$noc" self); c0=$(ticks "$noc" children); m0=$(mpv_ticks)
  sleep "$win"
  s1=$(ticks "$noc" self); c1=$(ticks "$noc" children); m1=$(mpv_ticks)
  local launches
  launches=$(grep -c . "$cache/bench-spawns.log" || true)
  printf '%-8s %-6s noctalia_self=%5d ms  noctalia_children=%5d ms  mpv=%5d ms  mpv_rss=%6d kB  plugin_launches=%3d\n' \
    "$rev_label" "$1" $(( (s1 - s0) * 1000 / hz )) $(( (c1 - c0) * 1000 / hz )) $(( (m1 - m0) * 1000 / hz )) "$(mpv_rss_kb)" "$launches"
  cut -f2,3 "$cache/bench-spawns.log" | cut -c1-60 | sort | uniq -c | sort -rn | sed 's/^/           /' | head -6
}

for rev in "$@"; do
  rev_label=$(git -C "$dir" rev-parse --short "$rev")
  msg plugin "$id:service" all stop || true
  msg plugins disable "$id"
  git -C "$dir" checkout -q "$rev"
  find "$cache/audio" "$cache/streams" -type f -delete 2>/dev/null || true
  rm -f "$cache/stats.json" "$cache/session.json" "$cache/cached_meta.json"
  msg plugins enable "$id"
  sleep 15
  measure idle

  msg panel-toggle "$id:panel"; sleep 2; msg panel-toggle "$id:panel"; sleep 1
  msg panel-toggle "$id:mini"; sleep 2; msg panel-toggle "$id:mini"; sleep 1
  msg plugin "$id:service" all replace_queue_and_play "@$queue"
  sleep 12
  # The upstream revision kills mpv on the 403 a fresh stream URL returns for
  # its first seconds; by now the URL is warm, so start it again.
  if ! mpv_alive; then
    echo "$rev_label: playback died on start (fresh-URL 403), restarting"
    msg plugin "$id:service" all replace_queue_and_play "@$queue"
  fi
  sleep 20
  mpv_alive || echo "$rev_label: mpv not running"
  measure play

  msg panel-toggle "$id:mini"; sleep 2
  measure mini
  msg panel-toggle "$id:mini"
  msg plugin "$id:service" all stop || true
done

git -C "$dir" checkout -q "$orig_rev"
msg plugins disable "$id"
msg plugins enable "$id"
