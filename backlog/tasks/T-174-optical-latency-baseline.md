---
id: T-174
title: Record the optical input-to-photon baseline (USB/Wi-Fi, 60/120 Hz)
status: todo
phase: 6
owner: user
depends_on: [T-168, T-173]
decisions: []
files:
  - docs/NOTES.md
  - tools/measure/optical/README.md
  - docs/decisions/
  - backlog/tasks/T-174-optical-latency-baseline.md
---

## Amaç

No physical end-to-end measurement exists for MateBridge: PLAN Faz 2 "Kalem gecikmesi ölçülür" is still unchecked, and the slow-motion camera idea from T-025 was never run. Every latency number so far is a software stage. This card records the first optical input-to-photon numbers (pen at 120 Hz, keyboard at 60 Hz, over USB and Wi-Fi) and explains the residual against the software stages from T-168 (and T-171 where available). The latency budgets (review B1) are then set from this baseline rather than adopted blind.

Source: external architecture review 2026-10-03 (LM3, B1, D5, H05); verification: docs/reviews/2026-10-03/verify-E-measurement.md (W5, LM3, B1, PF3).

## Bağlam

**Roles:** the user films and counts (hardware); the orchestrator writes `tools/measure/optical/README.md`, checks the logs from the same minute, computes the table and drafts the budgets decision. Device runs are one at a time (CLAUDE.md). Open question for the user (manifest §5 Q13): a 240 fps phone camera and a tripod, and ≥ 3 sessions per condition on different days.

**Why keyboard for 60 Hz (PF3):** on this tablet pen, touch, mouse and trackpad force the panel to 120 Hz; keyboard and gamepad let it fall to 60 Hz. A pen test is always a 120 Hz test. Confirm the rate in the same minute with `vsync_ms_p50` (≈ 8.3 ms at 120 Hz, ≈ 16.7 ms at 60 Hz) and T-169's `target_hz`.

**Software-visible estimate to compare against (verify-E B1, USB, 120 Hz, medians, an estimate, not a measurement):** input transit ~2 ms; Mac app + WindowServer + SCK composition ≥ 1 frame (unknown); callback→decode ≈ 17 ms (10.6 + 6.6 lead); ready→slot 13–17 ms; latch/scan-out ~4–8 ms. Total p50 ≈ 45–55 ms before any tail. The review's proposed 45 ms USB p95 budget is therefore likely too tight; set budgets only after this baseline (manifest §5 Q14).

**Procedure (user, with the orchestrator):**
1. Setup: phone at 240 fps (4.17 ms per frame) on a tripod, framing both the pen tip / key and the tablet screen. Krita brush smoothing "Yok" (or a minimal Mac canvas). Record build SHAs (T-145/T-146), mode (Akıcı), bitrate, transport. Start `scripts/device-smoke.sh` (T-173) and keep the client stats (T-168 fields) and, if T-171 has landed, host `ev=input_age` from the same minute.
2. **USB, 120 Hz, pen:** 30 discrete taps or short strokes. Measure from the frame where the tip touches the glass to the first frame where the mark appears.
3. **USB, 60 Hz, keyboard:** 30 key presses on the tablet keyboard into a Mac text field. Measure from the key-down frame to the glyph appearing. Confirm `vsync_ms_p50 ≈ 16.7`.
4. **Wi-Fi (BSD sockets, Akıcı):** repeat steps 2 and 3. Note the topology (Mac on Ethernet or Wi-Fi; see T-127).
5. Repeat each condition on ≥ 3 different days. Report p50/p95/max and the count of > 100 ms outliers per condition.
6. **Residual** = optical − (`cap_cb` (or `cap_rel` when the render callback is off) + 6.6 ms SCK lead (host `pts_vs_deliv`, T-170) + `input_age` p50 (T-171, if available; otherwise state that input transit is inside the residual)). The remainder is Mac app, WindowServer, SCK composition and panel time.
7. Commit only a frame-index CSV (frame numbers per event) if the orchestrator adds a counting script. **Never commit raw video.**

**Not carded, revisit after this card (manifest §4):** an input `seq` + `INPUT_ACK` on the wire, and a local cursor layer (review PK8/A5), only if the residual is unexplained or large.

## Kapsam dışı

- Code changes. Wire changes.
- The budgets decision itself: this card produces a *draft* (deferred decision "latency budgets", B1; numbered only when drafted).
- Pen line-quality evaluation (T-179, T-180).

## Kabul kriterleri

- [ ] [doc] `tools/measure/optical/README.md` holds the procedure above (setup, counting rule, residual formula, privacy: no raw video committed).
- [ ] [device] NOTES has a dated table per condition (USB pen 120 Hz, USB keyboard 60 Hz, Wi-Fi pen 120 Hz, Wi-Fi keyboard 60 Hz): n, p50, p95, max, count > 100 ms, ≥ 3 sessions on different days, with build SHAs, mode, bitrate, transport/topology and the measured `vsync_ms_p50`.
- [ ] [doc] The same NOTES entry gives the software stages from the same minute (T-168 `cap_dec`/`ready_slot`/`cap_cb`, host `pts_vs_deliv`, T-171 `input_age` if available) and the residual per condition.
- [ ] [doc] A budgets decision is drafted (status *önerildi*, unnumbered until the orchestrator assigns the next free number) with numbers taken from this baseline.
- [ ] No raw video is committed; at most a frame-index CSV.

## Plan

_(Ajan kodlamadan önce doldurur: adımlar, dokunulacak dosyalar, riskler.)_

## Handoff

_(Ajan bitirince doldurur.)_

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
