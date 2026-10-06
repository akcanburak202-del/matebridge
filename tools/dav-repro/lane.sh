#!/usr/bin/env bash
# T-266: PROPFIND latency while big files copy, Wi-Fi profile at 2 MB/s, with and without the small-request lane.
# Command line only (curl against the server directly, no mount, no Finder, no windows).
#
#   tools/dav-repro/lane.sh [port] [big-downloads] [propfinds] [files-in-folder]   (defaults 47812, 6, 40, 200; never 47010)
#
# Starts DavRepro (MB_DAV_DIRECT=1, MB_DAV_PROFILE=wifi, MB_DAV_RATE=2000000) on a temporary root twice (MB_DAV_LANE=0
# then 1). Each run: N downloads of a sparse 512 MB file run in the background (curl to /dev/null), then P sequential
# PROPFIND Depth:1 requests of a folder of N files, each on a NEW connection with the Digest handshake (what Finder's
# new connections do), timed with curl's time_total. Prints p50/p95/max per run. The token is never printed.
set -euo pipefail
cd "$(dirname "$0")/../.."
REPO=$(pwd)
PORT=${1:-47812}
BIG=${2:-6}
N=${3:-40}
FILES=${4:-200}
[ "$PORT" = 47010 ] && { echo "refusing port 47010"; exit 2; }

JH=${JAVA_HOME:-"/Applications/Android Studio.app/Contents/jbr/Contents/Home"}
export JAVA_HOME=$JH
export ANDROID_HOME=${ANDROID_HOME:-"$HOME/Library/Android/sdk"}
(cd client-android && ./gradlew --quiet compileDebugKotlin)
CLASSES=$REPO/client-android/app/build/intermediates/built_in_kotlinc/debug/compileDebugKotlin/classes
STDLIB=$(find "$HOME/.gradle/caches/modules-2/files-2.1/org.jetbrains.kotlin/kotlin-stdlib" -name 'kotlin-stdlib-2*.jar' \
  ! -name '*sources*' | sort -V | tail -1)

WORK=$(mktemp -d "${TMPDIR:-/tmp}/dav-lane.XXXXXX")
mkdir -p "$WORK/root/folder" "$WORK/classes"
for i in $(seq "$FILES"); do echo x > "$WORK/root/folder/file-$i.txt"; done
dd if=/dev/zero of="$WORK/root/big.bin" bs=1 count=0 seek=$((512 * 1024 * 1024)) 2>/dev/null
"$JH/bin/javac" -d "$WORK/classes" -cp "$CLASSES:$STDLIB" tools/dav-repro/DavRepro.java

MB_DAV_TOKEN=$(openssl rand -hex 16)
export MB_DAV_TOKEN
PIDS=()
cleanup() { for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null || true; done; rm -rf "$WORK"; }
trap cleanup EXIT

run() {
  local lane=$1
  MB_DAV_DIRECT=1 MB_DAV_PROFILE=wifi MB_DAV_LANE=$lane MB_DAV_RATE=2000000 \
    "$JH/bin/java" -cp "$WORK/classes:$CLASSES:$STDLIB" DavRepro "$WORK/root" "$PORT" > "$WORK/server$lane.txt" 2>&1 &
  local server=$!
  PIDS=("$server")
  for _ in $(seq 50); do grep -q "proxy  listening" "$WORK/server$lane.txt" 2>/dev/null && break; sleep 0.1; done
  local url="http://127.0.0.1:$PORT/MatePad"
  for _ in $(seq "$BIG"); do
    curl -s --digest -u "matebridge:$MB_DAV_TOKEN" -o /dev/null "$url/big.bin" &
    PIDS+=($!)
  done
  sleep 3 # let the downloads reach the cap
  : > "$WORK/times$lane.txt"
  for _ in $(seq "$N"); do
    curl -s --digest -u "matebridge:$MB_DAV_TOKEN" -X PROPFIND -H 'Depth: 1' -o /dev/null -w '%{time_total}\n' "$url/folder/" >> "$WORK/times$lane.txt"
  done
  for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null || true; done
  wait 2>/dev/null || true
  PIDS=()
  python3 -I -c '
import sys
t = sorted(float(x) * 1000 for x in open(sys.argv[1]) if x.strip())
q = lambda p: t[min(len(t) - 1, int(p * len(t)))]
print("lane=%s n=%d p50=%.0f ms p95=%.0f ms max=%.0f ms" % (sys.argv[2], len(t), q(.5), q(.95), t[-1]))
' "$WORK/times$lane.txt" "$lane"
}
echo "big downloads=$BIG, rate=2 MB/s, PROPFIND Depth:1 of $FILES files, new connection each"
run 0
run 1
