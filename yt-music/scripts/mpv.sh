#!/usr/bin/env bash
# Invoked via:  bash scripts/mpv.sh <fn> <args...>
#
# Playback state reaches the plugin through scripts/ytm.lua (loaded into mpv)
# over the IPC socket; commands go straight to the socket from Luau. This file
# only starts and stops mpv.

# Private per-user runtime dir (tmpfs, 0700) instead of a shared /tmp path.
DIR="${XDG_RUNTIME_DIR:-/run/user/$UID}/yt-music"
PIDFILE="$DIR/mpv.pid"
SOCK="$DIR/mpv.sock"
SCRIPT="${BASH_SOURCE[0]%/*}/ytm.lua"

mkdir -p -m 700 "$DIR"
if [ ! -O "$DIR" ] || [ -L "$DIR" ]; then
  echo "unsafe runtime dir: $DIR" >&2
  exit 1
fi

# Builtin sleep (bash loadables) keeps the wait loops fork-free.
enable -f /usr/lib/bash/sleep sleep 2>/dev/null || true

# mpv-mpris needs a multi-entry playlist to expose both transport directions.
DUMMY="av://lavfi:anullsrc=r=48000:cl=stereo"

# Serialize overlapping launches/kills (rapid skips): without this a newer
# launch can start while the older instance still holds the socket path.
# Released on process exit, even under SIGKILL.
lock() {
  exec 9>"$DIR/mpv.lock"
  flock 9 2>/dev/null || true
}

# Stop the instance recorded in the pidfile and wait (no polling processes)
# until it is gone so the socket path is free.
stop_previous() {   # $1=signal
  local prev=""
  [ -f "$PIDFILE" ] && read -r prev < "$PIDFILE"
  rm -f "$PIDFILE"
  if [ -n "$prev" ] && kill -"$1" "$prev" 2>/dev/null; then
    local i
    for i in {1..40}; do
      kill -0 "$prev" 2>/dev/null || break
      sleep 0.025
    done
    kill -0 "$prev" 2>/dev/null && kill -9 "$prev" 2>/dev/null
  fi
  rm -f "$SOCK"
}

mpv_play() {   # $1=volume $2=url_file $3=title_file $4=cover_file $5=cache_path $6=partial_path
  local vol="${1:-100}" url="" title="" t0="$EPOCHREALTIME"
  read -r url < "$2" || true
  IFS= read -r title < "$3" 2>/dev/null || true
  local extra=()
  # Feed mpv-mpris cover-art-files so system widgets get mpris:artUrl.
  [ -n "${4:-}" ] && [ -f "$4" ] && extra+=("--cover-art-file=$4")
  [ -n "${5:-}" ] && [ -n "${6:-}" ] && extra+=("--script-opts=ytm-cache=$5,ytm-partial=$6")

  lock
  stop_previous TERM
  # 9>&-: mpv must not inherit the lock fd, or the lock would outlive this
  # script (held open by the playing mpv) and deadlock the next play.
  nohup mpv "$DUMMY" "$url" "$DUMMY" --playlist-start=1 \
    --no-video --vo=null --vd=null --audio-display=no --no-osc --no-osd-bar \
    --demuxer-max-bytes=20M --demuxer-readahead-secs=60 --really-quiet --no-terminal \
    --keep-open=always --pause=no --volume="$vol" \
    --force-media-title="$title" \
    --script="$SCRIPT" "${extra[@]}" \
    --input-ipc-server="$SOCK" --ao=pipewire,pulse,alsa,auto \
    >/dev/null 2>&1 9>&- &
  echo $! > "$PIDFILE"
  local i
  for i in {1..150}; do
    [ -S "$SOCK" ] && break
    sleep 0.01
  done
  if [ -S "$SOCK" ]; then
    local ms=$(( (${EPOCHREALTIME/./} - ${t0/./}) / 1000 ))
    echo "READY=1 MS=$ms"
  fi
}

mpv_kill() {
  lock
  stop_previous 9
  # Strays from a crashed shell session, only seen at boot.
  pkill -9 -f "input-ipc-server=$SOCK" >/dev/null 2>&1
  rm -f "$SOCK"
}

fn="${1:?fn required}"; shift
case "$fn" in
  mpv_play|mpv_kill) "$fn" "$@" ;;
  *) echo "unknown fn: $fn" >&2; exit 1 ;;
esac
