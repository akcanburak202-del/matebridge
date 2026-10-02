#!/usr/bin/env bash
# T-138 repro: a QuickLook/Finder preview makes webdavfs download a whole big file while a small copy waits.
#
#   tools/dav-repro/bulk.sh [proxy-port]      (default 47812; never 47010, the running host's forward)
#
# Env knobs:
#   MB_BULK_FILES    big files in Download/ (default 1)
#   MB_BULK_GIB      size of each, sparse (default 2)
#   MB_BULK_EXT      extension of the big files (default mp4). mp4/mov: a real short movie (avconvert from a system
#                    .mov) padded with a 64-bit `free` box (bigmovie.py), so thumbnailers really decode it; other:
#                    sparse zeros.
#   MB_BULK_LAYOUT   tail (moov at the very end, like phone recordings; default) or faststart (moov first)
#   MB_BULK_TRIGGER  reads (default; readers.py: all videos at once open, read head + tail, hold MB_BULK_HOLD s, the
#                    thumbnailer's pattern without UI), ql (qlmanage -t), head (open + read 64 KB of each, keep open),
#                    none, finder (opens Download/ in a Finder window like the user does; shows UI on the Mac's
#                    screen, so it also needs MB_BULK_ALLOW_UI=1; the window goes away at unmount)
#   MB_BULK_HOLD     seconds readers.py keeps the files open (default 20)
#   MB_BULK_WAIT     seconds between trigger and the small copy (default 5)
#   MB_BULK_LIMIT    seconds a copy may take before it is called stuck (default 60)
#   MB_BULK_COPIES   141 KB copies (down, then up) while the trigger runs, 0.7 s apart (default 3)
#   MB_BULK_QLOFF=1  put an empty `.ql_disablethumbnails` at the volume root (QuickLook's per-volume switch)
#   MB_DAV_RATE      server rate cap, B/s (default the device's 20000000)
#   MB_DAV_MAXCONN   server connection limit (default the app's FilesConfig.MAX_CONNECTIONS)
#   MB_DAV_DIRECT=1  no logging proxy (the server listens on the port itself)
#
# Runs the tablet's DavServer on the Mac's JVM (DavRepro.java) on a temporary root, mounts it with the host's NetFS
# options at a temporary directory (never /Volumes), times a 141 KB copy while idle, starts the trigger, times the same
# copy again, and records who opens files on the volume (lsof), where webdavfs_agent's threads are (sample) and where
# the server's threads are (jstack). Then unmounts and deletes everything (also the webdavfs cache of the test mount).
set -euo pipefail
cd "$(dirname "$0")/../.."
REPO=$(pwd)
PORT=${1:-47812}
[ "$PORT" = 47010 ] && { echo "refusing port 47010 (the running host uses it)"; exit 2; }
FILES=${MB_BULK_FILES:-1}
GIB=${MB_BULK_GIB:-2}
EXT=${MB_BULK_EXT:-mp4}
LAYOUT=${MB_BULK_LAYOUT:-tail}
TRIGGER=${MB_BULK_TRIGGER:-reads}
HOLD=${MB_BULK_HOLD:-20}
WAIT=${MB_BULK_WAIT:-5}
LIMIT=${MB_BULK_LIMIT:-60}
COPIES=${MB_BULK_COPIES:-3}
export MB_DAV_RATE=${MB_DAV_RATE:-20000000}

JH=${JAVA_HOME:-"/Applications/Android Studio.app/Contents/jbr/Contents/Home"}
export JAVA_HOME=$JH
export ANDROID_HOME=${ANDROID_HOME:-"$HOME/Library/Android/sdk"}
(cd client-android && ./gradlew --quiet compileDebugKotlin)
CLASSES=$REPO/client-android/app/build/intermediates/built_in_kotlinc/debug/compileDebugKotlin/classes
STDLIB=$(find "$HOME/.gradle/caches/modules-2/files-2.1/org.jetbrains.kotlin/kotlin-stdlib" -name 'kotlin-stdlib-2*.jar' \
  ! -name '*sources*' | sort -V | tail -1)

WORK=$(mktemp -d "${TMPDIR:-/tmp}/dav-bulk.XXXXXX")
OUT=$WORK/out
mkdir -p "$WORK/root/Download" "$WORK/mnt" "$WORK/classes" "$OUT/ql"
echo hello > "$WORK/root/Download/readme.txt"
# MB_BULK_QLOFF=1: a `.ql_disablethumbnails` file at the volume root (QuickLook checks it on every new volume).
if [ "${MB_BULK_QLOFF:-0}" = 1 ]; then : > "$WORK/root/.ql_disablethumbnails"; fi
case "$EXT" in
  mp4|mov|m4v)
    SEED_SRC=/System/Library/CoreServices/ControlCenter.app/Contents/Resources/BentoGalleryIntroduction.mov
    FAST=--disableFastStart; [ "$LAYOUT" = faststart ] && FAST=
    avconvert --source "$SEED_SRC" --preset Preset1280x720 $FAST --output "$WORK/seed.$EXT" --replace > /dev/null
    ;;
esac
for i in $(seq "$FILES"); do
  f=$WORK/root/Download/video$i.$EXT
  if [ -f "$WORK/seed.$EXT" ]; then
    python3 tools/dav-repro/bigmovie.py "$WORK/seed.$EXT" "$f" "$GIB" "$LAYOUT" # valid movie, sparse padding
  else
    mkfile -n "${GIB}g" "$f"
  fi
done
head -c 144384 /dev/urandom > "$WORK/small.bin" # 141 KB, like the device report
for i in $(seq "$COPIES"); do cp "$WORK/small.bin" "$WORK/root/Download/small-$i.bin"; done # what the user copies
cp "$WORK/small.bin" "$WORK/root/Download/small-idle.bin" # same content, for the idle baseline (so not cached later)
mkdir -p "$WORK/local"
"$JH/bin/javac" -d "$WORK/classes" -cp "$CLASSES:$STDLIB" tools/dav-repro/DavRepro.java

MB_DAV_TOKEN=$(openssl rand -hex 16)
export MB_DAV_TOKEN
: > "$OUT/dump.txt" # appended to by the server and by mark(), so both survive
"$JH/bin/java" -cp "$WORK/classes:$CLASSES:$STDLIB" DavRepro "$WORK/root" "$PORT" >> "$OUT/dump.txt" 2>&1 &
SERVER=$!
BG=()
AGENT=
cleanup() {
  for p in "${BG[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null || true; done
  pkill -f "qlmanage -t -s 256 -o $OUT/ql" 2>/dev/null || true
  kill "$SERVER" 2>/dev/null || true # first: webdavfs' pending requests then fail at once and the unmount is quick
  umount "$WORK/mnt" 2>/dev/null || umount -f "$WORK/mnt" 2>/dev/null || true
  wait 2>/dev/null || true
  if [ -n "${MB_BULK_KEEP:-}" ]; then cp -R "$OUT" "$MB_BULK_KEEP" && echo "kept outputs in $MB_BULK_KEEP"; fi
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM
for _ in $(seq 50); do grep -q "proxy  listening" "$OUT/dump.txt" 2>/dev/null && break; sleep 0.1; done

now_ms() { perl -MTime::HiRes=time -e 'printf "%d\n", time*1000'; }
T0=$(now_ms)
mark() {
  local t=$(( $(now_ms) - T0 ))
  echo "$t ms: $*"
  printf '%8d script %s\n' "$t" "$*" >> "$OUT/dump.txt"
}

swift tools/dav-repro/mount.swift "http://127.0.0.1:$PORT/MatePad/" "$WORK/mnt"
AGENT=$(pgrep -f "webdavfs_agent.*127.0.0.1:$PORT/" | head -1 || true)
echo "agent pid=${AGENT:-?}"

# Who holds files open on the test volume (user processes; lsof without root sees the user's own). `-b` and no path
# argument so lsof does not stat the volume; it can still block for minutes while webdavfs is stalled, so it always
# runs in the background into a file.
holders() {
  lsof -b +c 0 -n -P -w 2>/dev/null | grep -F "$(basename "$WORK")/mnt/" | grep -v webdavfs_agent |
    awk '{print $1, $2, $4, $NF}' | sed -E "s#[^ ]*$(basename "$WORK")/mnt#<mnt>#" | sort -u
}

snapshot() { # $1 = label: webdavfs_agent threads (sample) + server threads (jstack) + holders (lsof, background)
  ( holders > "$OUT/holders-$1.tmp" && mv "$OUT/holders-$1.tmp" "$OUT/holders-$1.txt" ) & BG+=($!)
  [ -n "${AGENT:-}" ] && sample "$AGENT" 1 -file "$OUT/agent-$1.txt" > /dev/null 2>&1 || true
  "$JH/bin/jstack" "$SERVER" > "$OUT/server-$1.txt" 2>/dev/null || true
  mark "snapshot $1"
}

# Times one 141 KB copy: `up NAME` = Mac -> volume Download/NAME, `down NAME` = volume Download/NAME -> Mac (checked
# against the source). "STUCK" after $LIMIT s (a snapshot is taken halfway).
timed_copy() {
  local dir=$1 name=$2 start end pid snapped=0 src dst i
  if [ "$dir" = up ]; then src=$WORK/small.bin; dst=$WORK/mnt/Download/$name
  else src=$WORK/mnt/Download/$name; dst=$WORK/local/$name; fi
  start=$(now_ms)
  mark "copy $dir $name start"
  cp "$src" "$dst" 2> "$OUT/cp-$name.err" & pid=$!
  for i in $(seq $((LIMIT * 10))); do
    kill -0 "$pid" 2>/dev/null || break
    if [ $snapped = 0 ] && [ "$i" -ge $((LIMIT * 5)) ]; then snapshot "copy-$dir-$name"; snapped=1; fi
    sleep 0.1
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    mark "copy $dir $name STUCK > ${LIMIT}s"
    return
  fi
  end=$(now_ms)
  local rc=0 same=
  wait "$pid" || rc=$?
  if [ "$dir" = down ]; then
    if cmp -s "$WORK/small.bin" "$dst"; then same=" content=ok"; else same=" content=DIFFERENT"; fi
  fi
  mark "copy $dir $name done rc=$rc ms=$((end - start))$same $(tr '\n' ' ' < "$OUT/cp-$name.err")"
}

cache() {
  [ -n "${AGENT:-}" ] || return 0
  mark "$(lsof -p "$AGENT" 2>/dev/null | awk '/webdavcache/ {s += $7; n++} END {printf "webdavfs cache files=%d bytes=%d", n, s}')"
}

timed_copy down small-idle.bin
timed_copy up idle.bin
case "$TRIGGER" in
  ql)
    mark "trigger qlmanage -t on $FILES x .$EXT"
    qlmanage -t -s 256 -o "$OUT/ql" "$WORK"/mnt/Download/video*."$EXT" > "$OUT/ql.log" 2>&1 & BG+=($!)
    ;;
  reads)
    mark "trigger: readers.py on $FILES x .$EXT (open, head, tail, hold ${HOLD}s)"
    python3 tools/dav-repro/readers.py "$HOLD" "$WORK"/mnt/Download/video*."$EXT" > "$OUT/readers.log" 2>&1 & BG+=($!)
    ;;
  finder)
    # Opens a window on the Mac's screen: only with MB_BULK_ALLOW_UI=1 (never while someone works on the Mac).
    [ "${MB_BULK_ALLOW_UI:-0}" = 1 ] || { echo "finder trigger needs MB_BULK_ALLOW_UI=1"; exit 2; }
    mark "trigger: Finder window on Download/"
    open "$WORK/mnt/Download"
    ;;
  head)
    mark "trigger: open + read 64 KB of $FILES x .$EXT, keep open"
    for f in "$WORK"/mnt/Download/video*."$EXT"; do
      (exec 3<"$f"; head -c 65536 <&3 > /dev/null; sleep 600) & BG+=($!)
    done
    ;;
  none) mark "no trigger" ;;
esac
sleep "$WAIT"
cache
snapshot before-copy
for i in $(seq "$COPIES"); do
  timed_copy down "small-$i.bin"
  timed_copy up "busy-$i.bin"
  if [ "$i" -lt "$COPIES" ]; then sleep 0.7; fi
done
cache
snapshot after-copy
# Eject while the trigger may still hold a file open (Finder: "in use"): a plain unmount, no force.
if umount "$WORK/mnt" 2> "$OUT/umount.err"; then
  mark "plain unmount ok"
else
  mark "plain unmount FAILED: $(tr '\n' ' ' < "$OUT/umount.err")"
  snapshot eject
fi
for _ in $(seq 100); do ls "$OUT"/holders-*.tmp > /dev/null 2>&1 || break; sleep 0.2; done # up to 20 s for lsof
mark "end"

echo "---- marks ----"
grep -E " script " "$OUT/dump.txt"
echo "---- server summary ----"
grep -E "ev=stats" "$OUT/dump.txt" | awk '
  { for (i = 1; i <= NF; i++) { split($i, kv, "="); v[kv[1]] = kv[2] }
    out += v["bytes_out"]; n++
    if (v["reqs"] == 0 && v["bytes_out"] > 1000000) { stalled++; thr += v["throttled_ms"] } }
  END { printf "stats_lines=%d bytes_out_total=%d seconds_with_reqs0_and_streaming=%d (avg throttled_ms=%d)\n",
        n, out, stalled, stalled ? thr / stalled : 0 }'
grep -E "ev=stats" "$OUT/dump.txt" | tail -n 3
echo "connections_opened=$(grep -cE 'c[0-9]+ +open$' "$OUT/dump.txt" || true) (MB_DAV_DIRECT=1: no proxy, not counted)"
echo "---- GET heads (first 40) ----"
grep -E "> +GET " "$OUT/dump.txt" | sed -E 's/\| Host.*Range: (bytes=[0-9-]*).*/ Range: \1/; s/\| Host.*//' | head -n 40 || true
echo "---- holders (lsof: process, pid, fd, file) ----"
for f in "$OUT"/holders-*.txt; do [ -f "$f" ] && { echo "$(basename "$f"):"; sed 's/^/  /' "$f"; }; done
echo "---- threads: webdavfs_agent (sample) and server (jstack) ----"
python3 tools/dav-repro/threads.py "$OUT"/agent-*.txt "$OUT"/server-*.txt 2>/dev/null || true
echo "---- readers.py (ms since trigger) / qlmanage ----"
cat "$OUT/readers.log" 2>/dev/null || true
tail -n 3 "$OUT/ql.log" 2>/dev/null || true
