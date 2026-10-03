---
id: T-179
title: Measure Wi-Fi pen arrival rhythm after T-111 across 3 topologies
status: todo
phase: 6
owner: orchestrator
depends_on: [T-171, T-127]
decisions: []
files:
  - docs/NOTES.md
  - backlog/tasks/T-179-pen-wifi-rhythm-measurement.md
---

## Amaç

On Wi-Fi the pen samples reach the Mac in clusters, and the user found lines in Krita more angular than over USB. That data predates T-111, which moved the control connection to a kernel BSD socket, and nobody has re-measured since. This card measures the arrival rhythm again across three network topologies, together with the new host input-age numbers. The result decides whether the experimental host pen playout (T-198, decision 0024) is worth building at all. User and orchestrator run it together: the user holds the pen and judges Krita, and the orchestrator runs the tools.

Source: external architecture review 2026-10-03 (M04, D7, IN8); verification: docs/reviews/2026-10-03/verify-G-input.md (P-M04a, additional issue 5).

## Bağlam

**Why now:**
- Pre-T-111 numbers (NOTES 2026-09-30 "Faz 2 canlı deneme, devam", `docs/NOTES.md:168-176`): USB median 2.8 ms, p95 ~4 ms; Wi-Fi median 0.5–1.1 ms, p95 ~10 ms, longest gap 10.5–14 ms. They were measured over Network.framework with the Mac also on Wi-Fi.
- T-111's handoff asked for this check ("Wi-Fi'de kalem öbeklenmesinin … değişip değişmediği", `backlog/tasks/T-111-host-control-bsd-socket.md:190`). The answer was never recorded.
- The client cause of batching is already gone: T-026 sends one sample per PEN message (`max_batch` 1–2). Clusters now come from the network.
- The host ignores `base_time_us`/`dt_us` and posts each batch back to back (`host-mac/Sources/MateBridgeCore/Input/InputStateMachine+Pen.swift:16-24`, `host-mac/Sources/MateBridgeHost/Input/CGEventPoster.swift`).
- The line-quality benefit of any playout is unproven. In the Krita spike study (NOTES l.197-222), no timing change helped; only Krita smoothing = None did. That is why every run here uses smoothing = None.
- User decisions: "kalem Wi-Fi iyileştirmesi en sona", and drawing is done over USB (PLAN Aşama 5). This card only measures.
- **Dependency on T-127:** this card may run in the same device session as T-127, after T-127's rows are recorded. The dependency only ensures the topology setup and the build SHAs exist.

**Procedure (orchestrator; user holds the pen):**
1. Builds: record the host and APK commit SHAs from `ev=app_start` (T-145/T-146). If those cards have not landed, use the `git rev-parse --short HEAD` each build was made from. Also record macOS and HarmonyOS builds.
2. Mac receiver: write a scratch AppKit window app that logs mouse/tablet event receipt times. Set `NSEvent.isMouseCoalescingEnabled = false` **after** launch, because AppKit re-enables coalescing at launch (NOTES l.177 pitfall). Log only timestamps and event types, never coordinates. If T-173's `tools/measure/` has a receiver, use that instead.
3. Topologies, in this order:
   - (1) USB;
   - (2) Mac on Ethernet + tablet on Wi-Fi;
   - (3) both on Wi-Fi.
   Record the AP channel/width/DFS and the `awdl0` state (`ifconfig awdl0`). Optionally run this in the same session as T-127.
4. Workload per run: 6 fast circles in the receiver window, then the same in Krita (Fırça Pürüzsüzleştirme = Yok). At least 3 runs per topology.
5. Per run, collect:
   - Mac receiver: inter-event median, p95, max, and the share of intervals of 0–1 ms;
   - client input stats line: `pen_msgs`, `pen_samples`, `max_batch` (`MB` input counters);
   - host `input_session_end`;
   - host T-171 `ev=input_age`: pen **and pointer** p50/p95/p99/max, `late_250ms` and `clock_unc_us` p95;
   - client `MB/input` `merged=` per run. For every second with pen/pointer p99 > 100 ms or `late_250ms` > 0, also note that second's `merged=` (T-197's gate reads them together).
6. User verdict per topology: Krita line quality with smoothing = None (köşeli / temiz), in their own words.
7. Write a dated NOTES table in the same shape as l.170-174, add a "T-111 sonrası" row per topology, and state the verdict.

**Decision output (rule fixed before the first run):**
- A topology shows **clustering** when, in ≥ 2 of its 3 runs, the receiver inter-event median is < 1.5 ms or p95 is > 8 ms, **and** the user's Krita verdict (smoothing = None) for that topology says the Wi-Fi curves are still visibly more angular than USB ("köşeli").
- **"kümelenme sürüyor → T-198 açılabilir (0024)"** only if topology 2 (Mac Ethernet + tablet Wi-Fi) shows clustering, or topology 3 shows it and the user states that Ethernet is not an option for the Mac.
- **"Ethernet kullan / T-198 park"** if clustering appears only in topology 3 (both devices on Wi-Fi). Mac Ethernet is then the advice, not playout.
- **"kümelenme yok/önemsiz → T-198 park"** if no Wi-Fi topology shows clustering.

Wire: none. No code changes.

## Kapsam dışı

- Any host or client code change (playout is T-198, stale-input policy is T-199).
- CGEvent timestamp rewriting (rejected in 0024).

## Kabul kriterleri

- [ ] [device] For each of the 3 topologies, ≥3 runs: receiver median, p95, max and 0–1 ms share, client `pen_msgs`/`pen_samples`/`max_batch`/`merged=`, host `input_session_end` and T-171 `input_age` pen and pointer p50/p95/p99/max with `late_250ms`, all recorded.
- [ ] [device] The user's Krita verdict (smoothing = None) is recorded per topology.
- [ ] [doc] docs/NOTES.md has a dated entry with the results table, the build IDs (host SHA, APK SHA, macOS and HarmonyOS builds), the topology details (channel/width/DFS, AWDL) and no coordinates.
- [ ] [doc] NOTES states the decision for T-198 by the rule above (open / "Ethernet kullan, park" / park), with one line of reasoning.

## Plan

_(Ajan kodlamadan önce doldurur: adımlar, dokunulacak dosyalar, riskler.)_

## Handoff

_(Ajan bitirince doldurur.)_

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
