---
id: T-170
title: Make the host latency CSV joinable with the tablet trace; fix labels
status: done
phase: 6
owner: mac-host-dev
depends_on: [T-162]
decisions: []
files:
  - host-mac/Sources/MateBridgeCore/Video/LatencyTrace.swift
  - host-mac/Sources/MateBridgeHost/Video/LatencyCsv.swift
  - host-mac/Sources/MateBridgeHost/Video/HEVCEncoder.swift
  - host-mac/Sources/MateBridgeCore/Video/VideoSender.swift
  - host-mac/Sources/MateBridgeCore/Video/StatsSummary.swift
  - host-mac/Sources/MateBridgeHost/Session/StreamCoordinator.swift
  - host-mac/Tests/MateBridgeCoreTests/Video/
  - docs/LOGGING.md
  - backlog/tasks/T-170-host-latency-trace-join.md
---

## Amaç

The host's per-frame latency CSV (`MATEBRIDGE_LAT_TRACE=1`) writes the trace origin in its `capture_us` column, while the wire and the tablet's `pace_trace.csv` use the SCK presentation timestamp. The two traces therefore cannot be joined frame by frame, and the Mac menu still calls the tablet number "shown". After this card every host CSV row joins exactly with the tablet row of the same frame on `pts_us == capture_us`, the labels say "capture→decode", and the host logs the PTS-lead spread that decision 0021 (T-172) needs.

Source: external architecture review 2026-10-03 (H05, LM4, LM8, D5); verification: docs/reviews/2026-10-03/verify-E-measurement.md (W2, additional issue 2), docs/reviews/2026-10-03/verify-C-host-video.md (LM4).

## Bağlam

**Evidence:**
- `FrameTrace.captureUs` is the origin = `min(displayUs, ptsUs, deliveredUs)` (`LatencyTrace.swift:64-69`, set at `HEVCEncoder.swift:554-564`). On the device both SCK stamps lie ~6.6 ms *after* the callback (NOTES 2026-10-01 ~12:40, `pts_vs_deliv = +6,6 ms`), so the origin is in practice the callback time.
- The wire `capture_time_us` is the SCK PTS (`HEVCEncoder.swift:557`, `trace.ptsUs = captureTimeUs`). `FrameTrace.ptsUs` already holds it, but `csvHeader`/`csvLine` (`LatencyTrace.swift:83-88`) do not write it.
- The CSV has no `frame_seq`, `config_id` or `session_id` column. `frame_seq` is assigned only in `VideoSender` (`VideoSender.swift:88,99`, incremented at `:118`). The trace is completed in the send callback (`:101-114`).
- Idle re-submissions carry a synthetic stamp `now + lead` (`HEVCEncoder.swift:361-364`, `ResubmitStamp`). They need a `resubmit` flag so analysis can drop them.
- `ev=latency` already logs `pts_vs_deliv_ms_p50_99` (p50/p99 only; `LatencyTrace.swift:95,155-158`). Decision 0021 option A needs the spread `p99 − p1 < 1 ms`, so p1 must be added.
- `StatsSummary.swift:7` says "Capture -> shown on the tablet". `logFields` writes `latency_ms=` (`:30-31`), and `menuText` shows a bare "· N ms" (`:21-25`). The tablet number is capture-stamp → decoder output (T-168).
- The client trace header is `seq,capture_us,ready_ns,…` (`client/video/PaceTrace.kt:78`), where `capture_us` is the wire PTS.

**Plan hints:**
- Append new CSV columns at the end; keep the existing column order: `pts_us,display_us,frame_seq,config_id,session_id,resubmit`.
- Record `frame_seq` into the trace where `writeStartUs` is set (`VideoSender.swift:103-106`). `FrameTrace` is a value type that travels inside `EncodedVideoFrame`, so no lookup tables are needed.
- Stamp `session_id`/`config_id` in the sender's `trace:` closure at `StreamCoordinator.swift:425-429` (`link.sessionID`/`link.configID`), or pass them to `VideoSender`. Not at pipeline construction (`StreamCoordinator.swift:580`): the pipeline outlives sessions (lease `.reuse` across a reconnect today, reuse after park with T-165), so later sessions would get the wrong `session_id`. Touch `StreamCoordinator.swift` only there; `VideoPipeline.swift` then needs no change and is not in `files:`. If more is needed, stop and write it in *Açık sorular*.
- Add a signed PTS-origin `cap_to_sent_pts` (= `writeDoneUs − ptsUs`, signed) to `ev=latency`, next to the existing origin-based `cap_to_sent`.
- `StatsSummary`: comment and menu read "tablet capture→decode"; the `logFields` key `latency_ms` → `cap_dec_ms`, with `latency_ms` kept as an alias for one release.

**Order and hot files:**
- Serialize with the `HEVCEncoder.swift` chain T-162 → **T-170** → T-176 → T-177 → T-204 → T-187. T-162 is a dependency. T-176 must not be in progress at the same time (same file).
- `StreamCoordinator.swift` chain T-165 → T-167 → T-187 → T-196 → T-200: serialize with T-167 and T-187 (touch at the `VideoSender` construction only).
- `HEVCEncoder.swift` may be touched only for trace fields.

**Output for T-172:** the `pts_vs_deliv` p1/p50/p99 summary from a device run is the input for decision 0021 (option A if p99 − p1 < 1 ms).

## Kapsam dışı

- Changing the wire `capture_time_us` value or its semantics (decision 0021, T-172).
- Input timing (T-171, T-175).
- Client-side changes (T-168).
- New `ev=latency` stages beyond `cap_to_sent_pts` and the `pts_vs_deliv` p1.

## Kabul kriterleri

- [x] [XCTest] `FrameTrace.csvHeader` keeps today's columns in order and appends `pts_us,display_us,frame_seq,config_id,session_id,resubmit`. A test checks the header and one line, including a resubmitted frame (`resubmit=1`) and `pts_us` equal to the wire `capture_time_us`.
- [x] [XCTest] `VideoSender` records `frame_seq` into the trace equal to the `VIDEO_FRAME.frame_seq` it sends (fake transport).
- [x] [XCTest] `ev=latency` adds a signed `cap_to_sent_pts` stage and logs `pts_vs_deliv` as p1/p50/p99 (negative values allowed).
- [x] [XCTest] `StatsSummary`: the comment and `menuText` read "tablet capture→decode" (e.g. "· yak→çöz N ms"); `logFields` writes `cap_dec_ms=` and keeps `latency_ms=` as an alias.
- [x] [doc] `docs/LOGGING.md` documents the new CSV columns, `cap_to_sent_pts`, the `pts_vs_deliv` p1 and the `cap_dec_ms` rename.
- [ ] [device] A 60 s USB run with `MATEBRIDGE_LAT_TRACE=1` on the host and `--ez pace_trace true` on the client joins on `pts_us == capture_us` for ≥ 99 % of frames (resubmits excluded). The `pts_vs_deliv` p1/p50/p99 values are recorded in NOTES for T-172.
- [x] `./scripts/check.sh` geçiyor.

## Plan

1. `LatencyTrace.swift`: `FrameTrace` gets `frameSeq: UInt32`, `configID: UInt16`, `sessionID: UInt32`, `resubmit: Bool`. `csvHeader`/`csvLine` keep today's 7 columns and append `pts_us,display_us,frame_seq,config_id,session_id,resubmit` (`resubmit` 0/1). New signed `capToSentPtsUs` (`writeDoneUs - ptsUs`, nil if PTS unknown).
2. `LatencyWindow`: new signed series `cap_to_sent_pts` logged as `cap_to_sent_pts_ms_p50_95_99_max` (signed, after `cap_to_sent`); the offsets (`pts_vs_display`, `pts_vs_deliv`, `display_vs_deliv`) are logged as `_ms_p1_50_99` (p1 added). Field order: stages, `cap_to_sent_pts`, offsets, `no_display`.
3. `HEVCEncoder.swift` (trace fields only): `Input.resubmit` set in `resubmitLast`, copied into `trace.resubmit` in `send`.
4. `VideoSender.swift`: `timing.frameSeq = seq` where `writeStartUs` is set.
5. `StreamCoordinator.swift`: only the `trace:` closure at `VideoSender` construction stamps `link.sessionID`/`link.configID`.
6. `StatsSummary.swift`: comment "tablet capture→decode", menu "· yak→çöz N ms", `logFields` writes `cap_dec_ms=` plus alias `latency_ms=` (same value) for one release.
7. Tests in `Tests/MateBridgeCoreTests/Video/` (LatencyTraceTests, IntegrationTests: sender frame_seq + StatsSummary). `docs/LOGGING.md`: new separate block at the end.

Risks: `ev=latency` offset keys change name (`_p50_99` → `_p1_50_99`); analysis scripts that grep the old key must be updated (noted in LOGGING). No wire change.

## Handoff

- **Commit:** ec80138 (implementation; plan 25bef40; this handoff in the following commit)
- **Dokunulan dosyalar:** `host-mac/Sources/MateBridgeCore/Video/LatencyTrace.swift`, `host-mac/Sources/MateBridgeCore/Video/VideoSender.swift`, `host-mac/Sources/MateBridgeCore/Video/StatsSummary.swift`, `host-mac/Sources/MateBridgeHost/Video/HEVCEncoder.swift` (trace fields only: `Input.resubmit` set in `resubmitLast`, copied into the trace in `send`), `host-mac/Sources/MateBridgeHost/Video/LatencyCsv.swift` (comment only), `host-mac/Sources/MateBridgeHost/Session/StreamCoordinator.swift` (only the `trace:` closure at the `VideoSender` construction), `host-mac/Tests/MateBridgeCoreTests/Video/LatencyTraceTests.swift`, `host-mac/Tests/MateBridgeCoreTests/Video/IntegrationTests.swift`, `docs/LOGGING.md` (new separate block at the end), this card.
- **Varsayımlar:**
  - `session_id`/`config_id` come from the `VideoLink` captured when the sender is created (`link.sessionID`/`link.configID`), so a reused pipeline never stamps an old session. `VideoPipeline.swift` unchanged.
  - `resubmit=1` marks every `resubmitLast` path (static-screen keyframe, idle keyframe, idle refresh), i.e. every frame with a synthetic stamp.
  - The signed offsets' log keys were renamed `_ms_p50_99` → `_ms_p1_50_99` (self-describing format); no script in the repo reads the old key. `cap_to_sent_pts` skips frames whose PTS is unknown (0).
  - Menu text is Turkish like the rest of the menu: "· yak→çöz N ms". `ev=stats` writes `cap_dec_ms=` then `latency_ms=` with the same value.
  - Wire format unchanged; `docs/PROTOCOL.md` not touched.
- **Test edilmeyenler / cihazda doğrulanacaklar:**
  - [device] 60 s USB run, `MATEBRIDGE_LAT_TRACE=1` on the host and `--ez pace_trace true` on the client: join host `pts_us` with tablet `capture_us` on ≥ 99 % of frames (drop `resubmit=1`); also check `frame_seq` matches the tablet `seq` for joined rows and `session_id`/`config_id` match `host.log` after a reconnect / park-unpark.
  - Record `pts_vs_deliv_ms_p1_50_99` (p1/p50/p99) and `cap_to_sent_pts` from `ev=latency` in NOTES for T-172 (decision 0021, option A if p99 − p1 < 1 ms).
  - Menu shows "yak→çöz N ms" (not checked visually; no GUI opened).
- **Açık sorular:**
  - `latency_ms` alias removal needs a follow-up card in the next release.
