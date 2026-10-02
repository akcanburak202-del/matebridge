#!/usr/bin/env bash
# T-137 repro: tablet DavServer on the Mac's JVM + logging proxy + a real NetFS mount with the host's options.
#
#   tools/dav-repro/run.sh [proxy-port]      (default 47811; never 47010, the running host's forward)
#
# Builds client-android's debug classes, starts the server on a temporary root behind a logging proxy, mounts
# http://127.0.0.1:<proxy-port>/MatePad/ at a temporary directory (not /Volumes), times it, lists the volume,
# unmounts, and prints the HTTP head dump (Authorization reduced to its scheme; the token is never printed).
set -euo pipefail
cd "$(dirname "$0")/../.."
REPO=$(pwd)
PORT=${1:-47811}
[ "$PORT" = 47010 ] && { echo "refusing port 47010 (the running host uses it)"; exit 2; }

JH=${JAVA_HOME:-"/Applications/Android Studio.app/Contents/jbr/Contents/Home"}
export JAVA_HOME=$JH
export ANDROID_HOME=${ANDROID_HOME:-"$HOME/Library/Android/sdk"}
(cd client-android && ./gradlew --quiet compileDebugKotlin)
CLASSES=$REPO/client-android/app/build/intermediates/built_in_kotlinc/debug/compileDebugKotlin/classes
STDLIB=$(find "$HOME/.gradle/caches/modules-2/files-2.1/org.jetbrains.kotlin/kotlin-stdlib" -name 'kotlin-stdlib-2*.jar' \
  ! -name '*sources*' | sort -V | tail -1)

WORK=$(mktemp -d "${TMPDIR:-/tmp}/dav-repro.XXXXXX")
mkdir -p "$WORK/root/Pictures" "$WORK/root/Download" "$WORK/mnt" "$WORK/classes"
echo hello > "$WORK/root/Download/hello.txt"
"$JH/bin/javac" -d "$WORK/classes" -cp "$CLASSES:$STDLIB" tools/dav-repro/DavRepro.java

MB_DAV_TOKEN=$(openssl rand -hex 16)
export MB_DAV_TOKEN
"$JH/bin/java" -cp "$WORK/classes:$CLASSES:$STDLIB" DavRepro "$WORK/root" "$PORT" > "$WORK/dump.txt" 2>&1 &
SERVER=$!
cleanup() {
  umount "$WORK/mnt" 2>/dev/null || true
  kill "$SERVER" 2>/dev/null || true
}
trap cleanup EXIT
for _ in $(seq 50); do grep -q "proxy  listening" "$WORK/dump.txt" 2>/dev/null && break; sleep 0.1; done

# MB_DAV_VOLUMES=1: let NetFS pick the mount point under /Volumes as the host does (it becomes MatePad-1 while the
# real host's /Volumes/MatePad exists); it is unmounted again right after.
if [ "${MB_DAV_VOLUMES:-0}" = 1 ]; then MNT=-; else MNT=$WORK/mnt; fi
swift tools/dav-repro/mount.swift "http://127.0.0.1:$PORT/MatePad/" "$MNT" --unmount || true
sleep 1
echo "---- HTTP dump ($WORK/dump.txt) ----"
cat "$WORK/dump.txt"
