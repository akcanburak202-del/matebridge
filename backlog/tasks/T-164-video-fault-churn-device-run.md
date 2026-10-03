---
id: T-164
title: Run decoder fault injection and the surface-churn soak on the tablet
status: todo
phase: 6
owner: orchestrator
depends_on: [T-159, T-161]
decisions: []
files:
  - docs/NOTES.md
  - backlog/tasks/T-164-video-fault-churn-device-run.md
---

## Amaç

T-159 and T-161 are proven by JVM tests with a fake codec, but the real questions are device questions: does a decoder fault on the MatePad really turn input off before anything sticks on the Mac, does recovery bring the image back, and does repeated surface and mode churn return threads, codec instances and memory to baseline? This card runs those checks on the tablet and records dated results in docs/NOTES.md. It is the device evidence for D3.

Source: external architecture review 2026-10-03 (X3, X6, D3); verification: docs/reviews/2026-10-03/verify-B-client-video.md (P4) and docs/reviews/2026-10-03/verify-H-hygiene.md (additional issue 6).

## Bağlam

- **Owner:** the orchestrator runs the procedure (device tests one at a time, never from parallel agents, per CLAUDE.md); the user helps with the physical steps (holding Shift, pen down). No code changes in this card; any failure becomes its own card.
- **Prerequisites:** T-159 merged (debug extra `--es decoder_fault create|configure|dequeue|silent`, `ev=video_health`), T-161 merged (`ev=decoder_previous_stuck`, bounded hand-off). Record the host and client build IDs (T-145/T-146) in the NOTES entry; if those cards have not landed, record the commit SHAs.
- **Procedure A — fault injection (X3), 5 runs per mode (`create`, `configure`, `dequeue`, `silent`):**
  1. Connect over USB in Akıcı. Open a text editor and Krita on the tablet display.
  2. Start the app with the extra, e.g. `adb shell am start -n dev.matebridge.client/.MainActivity --es decoder_fault silent`.
  3. While the fault fires, the user holds Shift on the tablet keyboard and keeps the pen down in Krita.
  4. From the client log, measure the time from the fault (`ev=decoder_fault` / first `ev=video_health state=FAULT`) to `input_active on=0`.
  5. On the Mac: Shift is not stuck (type a lowercase letter), no stroke continues, host log has the `ev=input_release` line and no `input_post_failed` with `owed>0`.
  6. Measure the time from the fault to the first image after recovery (first decoded output, `video_health state=HEALTHY`) and note which recovery step (1 s restart, 3 s restart, reconnect, "Yeniden dene") brought it back.
- **Procedure B — churn soak (X6):**
  1. Baseline after 1 min of streaming: `adb shell ls /proc/$(adb shell pidof dev.matebridge.client)/task | wc -l` (threads), `adb shell dumpsys media.codec` (codec instances owned by the app), `adb shell dumpsys meminfo dev.matebridge.client` (TOTAL RSS/PSS).
  2. 100× background/foreground (Home, then reopen; a scripted `am start` / `input keyevent HOME` loop is fine).
  3. 100× mode change (alternate Netlik ↔ Akıcı so the display is recreated half the time, plus Akıcı ↔ Performans).
  4. Surface churn: GL ↔ SurfaceView fallback churn (`--es render gl`) only if T-184 has not yet removed the GL path; otherwise mark it "not applicable".
  5. Repeat the measurements from step 1 after 1 min of settling. Pass: threads, codec instances and RSS back to baseline ±5 %.
  6. Count in the client log: `detach_slow`, `decoder_previous_stuck`, `audio_previous_slow`, and `audio_out` lines whose `api=` shows a fallback from the normal path (H add. 6: the audio generation overlap; it falls back to SHARED/TRACK rather than crashing).
- **Logs:** pull with the usual scripts; never commit raw logs, serials or personal data (AGENTS.md). NOTES gets the numbers only.
- Runs that were not performed are written as "not run" with the reason; they are not left out.

## Kapsam dışı

- Fixing anything found (separate cards).
- Wi-Fi-specific runs; host-side encoder faults (T-162 has its own device check).

## Kabul kriterleri

- [ ] [device][doc] Procedure A: for each of the 4 fault modes, 5 runs recorded in docs/NOTES.md (dated, with build IDs): fault → `input_active on=0` time, host owed-release count = 0 with Shift held and pen down, time to first image after recovery, recovery step used.
- [ ] [device][doc] Procedure B: threads, `dumpsys media.codec` instances and RSS at baseline and after 100× fg/bg + 100× mode change (+ GL churn if applicable), with the ±5 % verdict.
- [ ] [doc] Counts of `detach_slow`, `decoder_previous_stuck`, `audio_previous_slow` and audio `api=` fallbacks are recorded.
- [ ] [doc] Every skipped run is marked "not run" with a reason; each failure has a follow-up card ID or an *Açık sorular* note here.

## Plan

_(Ajan kodlamadan önce doldurur: adımlar, dokunulacak dosyalar, riskler.)_

## Handoff

_(Ajan bitirince doldurur.)_

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
