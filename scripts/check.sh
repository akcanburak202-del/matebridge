#!/usr/bin/env bash
# Single verification entry point for agents and the orchestrator.
# Builds and tests every component that exists; components not yet created are skipped.
# Exit code is non-zero if anything that exists fails.
#
# Usage: scripts/check.sh                      # host, android, protocol, measurement kit (the pre-handoff gate)
#        scripts/check.sh --probes             # also build/test the concluded probes/ (decision 0026, 2026-10-08)
#        scripts/check.sh --only host           # host-mac swift build + test
#        scripts/check.sh --only android        # client-android assembleDebug testDebugUnitTest
#        scripts/check.sh --only protocol       # fixtures up to date, crypto vectors (macOS only), fixture docs
# --only is repeatable and takes a comma list (--only host,protocol). Probes run only with --probes.
set -uo pipefail
cd "$(dirname "$0")/.."

usage() { # usage [exit code]
  sed -n '6,11p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit "${1:-2}"
}

# Selected components as a space-separated string; empty means "all" (today's full run).
# A string, not an array: macOS /bin/bash 3.2 treats an empty array as unbound under `set -u`.
only=""
probes=""
add_only() { # add_only <comma list>
  local item before=$only
  for item in $(echo "$1" | tr ',' ' '); do
    case $item in
      host|android|protocol) only="$only $item" ;;
      *) echo "check.sh: unknown component '$item' (host, android, protocol)" >&2; usage ;;
    esac
  done
  [ "$only" != "$before" ] || { echo "check.sh: --only needs a component" >&2; usage; }
}
while [ $# -gt 0 ]; do
  case $1 in
    --only) [ $# -ge 2 ] || { echo "check.sh: --only needs a component" >&2; usage; }; add_only "$2"; shift 2 ;;
    --only=*) add_only "${1#--only=}"; shift ;;
    --probes) probes=1; shift ;;
    -h|--help) usage 0 ;;
    *) echo "check.sh: unknown argument '$1'" >&2; usage ;;
  esac
done
want() { [ -z "$only" ] || case " $only " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
[ -z "$only" ] || echo "check.sh: only$only"

fail=0
run() { # run <label> <dir> <cmd...>
  local label=$1 dir=$2; shift 2
  echo "==> $label"
  if (cd "$dir" && "$@"); then echo "    OK: $label"; else echo "    FAIL: $label"; fail=1; fi
}

# Under --only a selected component must exist, so CI cannot pass by checking nothing
missing() { # missing <component> <path>
  if [ -n "$only" ] && want "$1" && [ ! -e "$2" ]; then echo "    FAIL: --only $1 but $2 is missing"; fail=1; fi
}
missing host host-mac/Package.swift
missing android client-android/gradlew
missing protocol protocol/fixtures/gen.py

# macOS host + Swift probes (any directory with a Package.swift); probes only with --probes
if want host; then
  for pkg in host-mac probes/*; do
    [ -f "$pkg/Package.swift" ] || continue
    [ "$pkg" = host-mac ] || { [ -z "$only" ] && [ -n "$probes" ]; } || continue
    run "swift build ($pkg)" "$pkg" swift build
    if [ -d "$pkg/Tests" ]; then run "swift test ($pkg)" "$pkg" swift test; fi
  done
fi

# Android client + Android probes (any directory with a Gradle wrapper); probes only with --probes
if want android; then
  AS_JBR="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
  if [ -z "${JAVA_HOME:-}" ] && [ -d "$AS_JBR" ]; then export JAVA_HOME="$AS_JBR"; fi
  if [ -z "${ANDROID_HOME:-}" ] && [ -d "$HOME/Library/Android/sdk" ]; then export ANDROID_HOME="$HOME/Library/Android/sdk"; fi
  for proj in client-android probes/*; do
    [ -x "$proj/gradlew" ] || continue
    [ "$proj" = client-android ] || { [ -z "$only" ] && [ -n "$probes" ]; } || continue
    if [ -z "${JAVA_HOME:-}" ]; then echo "    FAIL: $proj needs a JDK (install Android Studio)"; fail=1; continue; fi
    tasks="assembleDebug testDebugUnitTest"
    [ "$proj" = client-android ] && tasks="assembleDebug assembleDaily testDebugUnitTest"  # only the client has a daily type (T-301)
    run "gradle ($proj)" "$proj" ./gradlew --quiet $tasks
  done
fi

if want protocol; then
  # Protocol fixtures must be up to date with the reference encoder
  if [ -f protocol/fixtures/gen.py ]; then
    run "protocol fixtures up to date" . python3 protocol/fixtures/gen.py --check
  fi

  # Crypto test vectors (PROTOCOL.md section 9) must match the reference generator (CryptoKit: macOS only)
  if [ -f protocol/fixtures/crypto_vectors.swift ]; then
    if [ "$(uname -s)" = Darwin ]; then
      run "crypto vectors up to date" . bash -c 'swift protocol/fixtures/crypto_vectors.swift | diff -q - protocol/fixtures/crypto_vectors.json >/dev/null'
    else
      echo "==> crypto vectors up to date"
      echo "    SKIP (needs macOS): crypto vectors up to date"
    fi
  fi

  # Protocol fixtures must be referenced by docs (cheap consistency guard)
  for fx in protocol/fixtures/*.hex; do
    [ -e "$fx" ] || continue
    name=$(basename "$fx" .hex)
    grep -q "$name" docs/PROTOCOL.md || { echo "    FAIL: fixture $name not documented in docs/PROTOCOL.md"; fail=1; }
  done
fi

# Measurement kit (T-173): offline self-test with stubs, no device; full run only (like the probes).
# The host tools use BSD stat/top, so macOS only; on failure only the failed checks are printed.
if [ -z "$only" ] && [ -x tools/measure/selftest.sh ]; then
  if [ "$(uname -s)" = Darwin ]; then
    run "measurement kit selftest" . bash -c 'o=$(tools/measure/selftest.sh 2>&1) || { echo "$o" | grep -v "    ok: "; exit 1; }'
  else
    echo "==> measurement kit selftest"
    echo "    SKIP (needs macOS): measurement kit selftest"
  fi
fi

if [ $fail -eq 0 ]; then echo "check.sh: ALL OK"; else echo "check.sh: FAILURES"; fi
exit $fail
