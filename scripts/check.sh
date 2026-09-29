#!/usr/bin/env bash
# Single verification entry point for agents and the orchestrator.
# Builds and tests every component that exists; components not yet created are skipped.
# Exit code is non-zero if anything that exists fails.
set -uo pipefail
cd "$(dirname "$0")/.."

fail=0
run() { # run <label> <dir> <cmd...>
  local label=$1 dir=$2; shift 2
  echo "==> $label"
  if (cd "$dir" && "$@"); then echo "    OK: $label"; else echo "    FAIL: $label"; fail=1; fi
}

# macOS host + Swift probes (any directory with a Package.swift)
for pkg in host-mac probes/*; do
  [ -f "$pkg/Package.swift" ] || continue
  run "swift build ($pkg)" "$pkg" swift build
  if [ -d "$pkg/Tests" ]; then run "swift test ($pkg)" "$pkg" swift test; fi
done

# Android client + Android probes (any directory with a Gradle wrapper)
AS_JBR="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
if [ -z "${JAVA_HOME:-}" ] && [ -d "$AS_JBR" ]; then export JAVA_HOME="$AS_JBR"; fi
for proj in client-android probes/*; do
  [ -x "$proj/gradlew" ] || continue
  if [ -z "${JAVA_HOME:-}" ]; then echo "    FAIL: $proj needs a JDK (install Android Studio)"; fail=1; continue; fi
  run "gradle ($proj)" "$proj" ./gradlew --quiet assembleDebug testDebugUnitTest
done

# Protocol fixtures must be referenced by docs (cheap consistency guard)
for fx in protocol/fixtures/*.hex; do
  [ -e "$fx" ] || continue
  name=$(basename "$fx" .hex)
  grep -q "$name" docs/PROTOCOL.md || { echo "    FAIL: fixture $name not documented in docs/PROTOCOL.md"; fail=1; }
done

if [ $fail -eq 0 ]; then echo "check.sh: ALL OK"; else echo "check.sh: FAILURES"; fi
exit $fail
