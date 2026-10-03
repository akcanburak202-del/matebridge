---
id: T-172
title: Record decision 0021 and correct the latency and late-input prose
status: todo
phase: 6
owner: orchestrator
depends_on: [T-170]
decisions: [0021]
files:
  - docs/decisions/0021-capture-timestamp-semantics.md
  - docs/decisions/README.md
  - docs/PROTOCOL.md
  - docs/LOGGING.md
  - protocol/fixtures/
  - backlog/tasks/T-172-latency-semantics-docs.md
---

## Amaç

PROTOCOL.md says the STATS latency is "Yakalama → ekranda gösterim" (capture → on-screen display), but the code measures capture-stamp → decoder output, and the wire `capture_time_us` (SCK PTS) lies ~6.6 ms after the host's real capture origin, so the tablet under-reports. PROTOCOL §4 also names the 1 s client queue as the bound on late input, while the real bound is the host's 5 s silence close. This card records what `capture_time_us` means (decision 0021), using T-170's measured PTS-lead spread, and corrects the latency and late-input prose so nobody compares host and tablet numbers as if they shared an origin.

Decision 0021 must be accepted by the user before work starts (the orchestrator drafts it with the T-170 data; the "decoder output" wording fix applies under either option).

Source: external architecture review 2026-10-03 (H05, LM4, M04); verification: docs/reviews/2026-10-03/verify-C-host-video.md (LM4-D), docs/reviews/2026-10-03/verify-E-measurement.md (W4, additional issue 3), docs/reviews/2026-10-03/verify-G-input.md (additional issue 2), docs/reviews/2026-10-03/verify-F-network.md (A-5), docs/reviews/2026-10-03/coverage-audit.md (§4.3 merge, T5).

## Bağlam

**Facts (both C and E agree):**
- Wire `VIDEO_FRAME.capture_time_us` = SCK presentation timestamp (`host-mac/Sources/MateBridgeHost/Video/HEVCEncoder.swift:553-557`; PROTOCOL §0x41, `docs/PROTOCOL.md:530`). Idle re-submissions use `now + lead` (`ResubmitStamp`, `HEVCEncoder.swift:361-364`).
- The host trace origin is `min(displayTime, PTS, delivered)` (`host-mac/Sources/MateBridgeCore/Video/LatencyTrace.swift:64-69`), in practice the SCK callback. PTS lies **+6.6 ms after** the callback (NOTES 2026-10-01 ~12:40, `pts_vs_deliv`). So the tablet's number **under-reports** by ~6.6 ms. (C's "not older" correction is partly a translation artifact, coverage audit T5; keep the fact, not the "review was wrong" framing.)
- The tablet pacer (`client/video/AdaptivePacer.kt:8-9`) and A/V sync (PROTOCOL §6; AUDIO `capture_time_us` uses the same clock, `docs/PROTOCOL.md:507`) depend on the current stamp, so changing its meaning is not free.
- Already known and never resolved: T-072 Handoff *Açık sorular* (`backlog/tasks/T-072-host-latency-metric-and-hold.md:50`).
- Wrong prose today:
  - `docs/PROTOCOL.md:456` (§0x22 `latency_avg_us`): "Yakalama → ekranda gösterim".
  - `docs/PROTOCOL.md:573` (§6): `latency = gösterim_zamanı − (capture_time_us − offset)`.
  - `docs/PROTOCOL.md:300` (§4 PEN, "Kabul edilen davranış"): "Gecikmenin üst sınırı istemci kuyruk sınırıdır (§5, 1 sn)". Bytes already in the client's kernel socket buffer have no age limit (client `SessionController.kt:641`: only `tcpNoDelay`; `SendQueue.kt` checks age at `offer` only). The real bound is the host's 5 s silence close (§6). Between 1.5 s and 5 s a release-all and latch happen, yet complete later clicks, keys and strokes can still replay late.
- macOS `unacked_bytes`/`notsent_bytes` (T-126) degenerate to `unacked = sbbytes`, `notsent = 0` when cwnd ≫ sbbytes (`host-mac/Sources/MateBridgeCore/Session/TcpInfoLog.swift:62-67`, verify-F A-5). LOGGING says "tahmin" (`docs/LOGGING.md:59-61`) but not that the split is meaningless in that regime.

**Decision 0021 options** (draft in the manifest §1; numbering per the manifest):
- **(A) recommended if T-170 shows `pts_vs_deliv` p99 − p1 < 1 ms:** no wire change. The tablet numbers are named "capture-stamp→…"; analysis adds the host-logged lead. End-to-end budgets = host `cap_to_sent` (callback origin) + network + client stages.
- **(B):** append `origin_offset_us: i32` (= origin − `capture_time_us`, ≤ 0) after `data` in `VIDEO_FRAME` (trailing fields allowed by §2). This is **wire**: new golden vector `video_frame_origin`, both fixture tests, and two follow-up implementation cards (host + client) created by the orchestrator.
- **Either option:** §0x22 and §6 say "decoder output", not "ekranda gösterim".

**Procedure (orchestrator):**
1. Take the `pts_vs_deliv` p1/p50/p99 from T-170's device run (NOTES) and, if available, a Wi-Fi run.
2. Draft `docs/decisions/0021-capture-timestamp-semantics.md` (Turkish, template in `docs/decisions/README.md`, status *önerildi*), add the README table row, and get user acceptance.
3. Edit PROTOCOL.md (§0x22, §6, §4 "Kabul edilen davranış") and LOGGING.md in one doc commit. Batch with the other phase-6 PROTOCOL prose edits where timing allows (manifest "Serialize-with": T-150/0018, T-152, T-163, T-171 §6 line, T-189, T-196, T-199).
4. Run `python3 protocol/fixtures/gen.py --check`.
5. Only if option B: write the fixture and create the two follow-up cards.

## Kapsam dışı

- Code changes (the client renames are T-168, the host labels T-170).
- The stale-input policy itself (decision 0025, T-199). This card only states the real bound.
- Latency budgets (B1): drafted after T-174.

## Kabul kriterleri

- [ ] [doc] `docs/decisions/0021-capture-timestamp-semantics.md` is recorded with the T-170 `pts_vs_deliv` p1/p50/p99 data and the chosen option, accepted by the user; `docs/decisions/README.md` has the row.
- [ ] [doc] PROTOCOL §0x22 `latency_avg_us` and the §6 formula say "decoder output" (capture stamp → decoder output, clock-corrected estimate), not "ekranda gösterim". No byte changes.
- [ ] [doc] PROTOCOL §4 "Kabul edilen davranış" states that the real late-input bound is the host's 5 s silence close (§6), not the 1 s client queue, and that late complete clicks/keys/strokes can replay after a 1.5–5 s stall.
- [ ] [doc] LOGGING.md notes that tablet `latency_us`/`cap_dec_*` exclude the SCK lead (~6.6 ms, host `pts_vs_deliv`) and pacing, and that macOS `unacked_bytes` should be read as `sbbytes` when cwnd ≫ sbbytes.
- [ ] `python3 protocol/fixtures/gen.py --check` is green.
- [ ] **Only if option B:** fixture `video_frame_origin` added, both fixture tests pass, two follow-up cards (host + client) created; `./scripts/check.sh` geçiyor.

## Plan

_(Ajan kodlamadan önce doldurur: adımlar, dokunulacak dosyalar, riskler.)_

## Handoff

_(Ajan bitirince doldurur.)_

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
