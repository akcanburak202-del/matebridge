#!/usr/bin/env bash
# Host soak sampler (T-173, T-194): tools/measure/macmon.sh --soak every 60 s (RSS, open files, threads, instance
# count, host.log event counts, CPU/GPU). Read-only; opens no window.
#
# Usage: tools/soak/host-soak.sh --out FILE [--seconds N] [--proc NAME]...
#   Long runs: nohup tools/soak/host-soak.sh --out ~/mb-soak/host-soak.txt >/dev/null 2>&1 &   (stop: kill %1 / kill PID)
exec "$(cd "$(dirname "$0")" && pwd)/../measure/macmon.sh" --soak --interval 60 "$@"
