---
id: T-173
title: Version the measurement and soak scripts and add device-smoke.sh
status: todo
phase: 6
owner: orchestrator
depends_on: [T-145, T-146]
decisions: []
files:
  - tools/measure/
  - tools/soak/
  - scripts/device-smoke.sh
  - docs/WORKFLOW.md
  - docs/NOTES.md
  - backlog/tasks/T-173-measurement-kit-smoke.md
---

## Amaç

The power, refresh and fps tools used for the October measurements (`mbmon.sh`, `an.py`, `macmon.sh`, `macan.py`) lived only in scratch and are lost, and no single command records which build, codec, panel rate, mode and transport a number came from. Performance claims in NOTES are therefore hard to reproduce and easy to cherry-pick (single runs, filtered seconds). After this card the measurement and soak tools are versioned in the repo, and `scripts/device-smoke.sh` captures the build identity plus a 60 s numeric stats window in one command. T-127, T-174 and T-194 build on it.

Source: external architecture review 2026-10-03 (M07, D5, D10); verification: docs/reviews/2026-10-03/verify-E-measurement.md (W6, M07 measurement bullets, PF1), docs/reviews/2026-10-03/verify-H-hygiene.md (SOAK-1 tooling), docs/reviews/2026-10-03/coverage-audit.md (§4.3 merge: one card, one directory per purpose).

## Bağlam

**Evidence:**
- `scripts/` holds only `board.sh`, `bundle-host.sh`, `check.sh`, `codex-review.sh`, `install-apk.sh`, `make-mac-icon.swift`, `usb-mode.sh`. No smoke command exists.
- The recipes are described in NOTES: ~l.1070 (`mbmon.sh`: 1 Hz panel rate, temperature, frequency, CPU shares to `/data/local/tmp/mbmon.txt`; `an.py`: window summary of `MB/decoder recv` and AGP touch events) and ~l.1119 ("Ölçüm araçları scratch'teydi … kayboldularsa"). The power/fps method is in the T-140/T-141 sections around ~l.1060–1080.
- The precedent for versioned tools is `tools/pacing/` (`README.md`, `sim.py`, `gaps.py`, an anonymised timing-only CSV).
- The only soak evidence is a 30 min run on an old build (NOTES 2026-09-30). PLAN's exit criterion is a week of daily use.
- PF1 (verify-E): the 2026-10-03 drawing numbers were single runs filtered to dense seconds, the pattern M07 warns about. Hence the result-header and run-count rules below.
- Build identity comes from T-145 (host log/menu SHA) and T-146 (client log/settings SHA); this card reads them, it does not add them.

**Layout (coverage audit §4.3: E W6 and H SOAK-1 both recreated `mbmon.sh`/`macmon.sh` in different places; merged here):**
- `tools/measure/`: `mbmon.sh` (tablet 1 Hz sampler), `an.py` (tablet window summary), `macmon.sh` (host sampler), `macan.py` (host summary), `README.md` (recipes, result-header format).
- `tools/soak/`: tablet and host 60 s samplers and `summarize.py`. Reuse `tools/measure/` samplers where possible instead of copying them.
- `scripts/device-smoke.sh`: one command, read-only on both devices.

**Soak sampler content (H SOAK-1), every 60 s:**
- Host: RSS (`ps -o rss`), open files (`lsof -p <pid> | wc -l`), threads (`ps -M`).
- Tablet: PSS (`dumpsys meminfo dev.matebridge.client`), `/proc/<pid>/fd` count (via `run-as` if needed), threads grouped by name prefix (`ps -T -p <pid>`: `mb-ctl-read-*`, `mb-video-*`, `mb-audio-*`, `mb-decoder*`, …), codec instances (`dumpsys media.codec` / `dumpsys media.resource_manager`).
- Log event counts: `decoder_give_up`, `detach_slow`, `audio_previous_slow`, `pipeline_retry`, `release_all`, reconnects.

**Privacy (AGENTS.md):** the smoke and soak scripts must filter logs to numeric fields of known stats lines. No clipboard, key, text or file-name lines; no device serial numbers in committed output. Keycodes never appear.

**Rules:** bash and python3 stdlib only, so no decision record is needed (AGENTS.md "no dependencies without a decision"). Scripts must not install, change settings, or start/stop the apps; device tests stay one at a time (CLAUDE.md).

## Kapsam dışı

- CI (T-149) and instrumentation tests.
- Running the 8 h / one-week soak (T-194) and the optical test (T-174).
- New log fields in the apps (T-168, T-169, T-170, T-171 add those; the scripts read whatever exists and print `-` for missing fields).

## Kabul kriterleri

- [ ] `scripts/device-smoke.sh` prints: host and APK build SHA (T-145/T-146 log lines), host macOS version, tablet `ro.build.display.id`, decoder name (`ev=codec_start`), `stream_config`, panel Hz and `vsync_ms_p50`, stream mode and transport. It then collects 60 s of `MB/render ev=stats`, `MB/decoder ev=stats` and host `ev=latency`/`ev=stats` lines, keeps numeric fields only, and prints p50/p95 of the key fields to stdout.
- [ ] `tools/measure/` holds `mbmon.sh`, `an.py`, `macmon.sh`, `macan.py` and a `README.md` with the recipes, rewritten from the NOTES descriptions.
- [ ] `tools/soak/` samplers record the host and tablet values listed in *Bağlam* every 60 s, plus the log-event counts; `summarize.py` prints per-hour trends and slopes (RSS/PSS, fds, threads per prefix, codec instances).
- [ ] Every result header produced by the tools names: commit SHAs, macOS and HarmonyOS builds, codec, topology/transport, resolution, target and real Hz, bitrate, content, duration and run count (≥ 3 for any claim).
- [ ] [doc] `docs/WORKFLOW.md` gains one paragraph: how to run `device-smoke.sh` and the result-header rule.
- [ ] No clipboard, key, text or serial-number content in any script output (grep-check documented in the README); bash and python3 stdlib only.
- [ ] [device] One `device-smoke.sh` run over USB and one over Wi-Fi; the outputs (numbers only) are pasted into NOTES with build IDs.
- [ ] `bash -n` and `python3 -m py_compile` pass for all new scripts; `./scripts/check.sh` geçiyor.

## Plan

_(Ajan kodlamadan önce doldurur: adımlar, dokunulacak dosyalar, riskler.)_

## Handoff

_(Ajan bitirince doldurur.)_

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
