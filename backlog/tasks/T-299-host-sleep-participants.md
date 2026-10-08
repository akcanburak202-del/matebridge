---
id: T-299
title: Host — uyku katılımcıları hiç kayıt olmuyor; girdi ve ses uyku anında oturum kuyruğundan bağımsız bırakılsın (T-132 eksiği)
status: review
phase: 7
owner: mac-host-dev
depends_on: []
decisions: []
files:
  - host-mac/Sources/MateBridgeHost/Input/InputController.swift
  - host-mac/Sources/MateBridgeHost/Audio/SystemAudioTap.swift
  - host-mac/Sources/MateBridgeHost/Audio/HostAudio.swift
  - host-mac/Sources/MateBridgeHost/Session/HostSleepParticipants.swift
  - host-mac/Sources/MateBridgeHost/Session/SessionServer.swift
  - host-mac/Sources/MateBridgeCore/Session/HostSleep.swift
  - host-mac/Tests/MateBridgeCoreTests/Session/
  - backlog/tasks/T-299-host-sleep-participants.md
---

## Amaç

T-297 incelemesi, bulgu B1 (`docs/reviews/2026-10-08/agents/simp-b-host-session.md`; orkestratör doğruladı). `HostSleepParticipants` (`HostSleepParticipants.swift`) tanımlı ve `SessionServer.onPower` her `will_sleep`'te `snapshot()` alıp katılımcıları bekliyor. Ama üretim kodunda hiçbir yer `register(` çağırmıyor, yani liste her zaman boş.

T-132 Handoff'u "InputController `start()`'ta `input`, SystemAudioTap `init`'te `audio` olarak kayıt olur" diyor, ama ef3f5079 bunu içermiyor (`git log -S releaseOnQueue` yalnız kart metnini buluyor). Sonuç: uyku anında girdinin release-all'u yalnız oturum kuyruğu üzerinden (`machine.hostSleep()`) yapılıyor. Kuyruk takılırsa Codex P1'in istediği yedek yol yok. `host_sleep_ack` logunda `input=`/`audio=` alanları hiç görünmüyor.

## Kabul

1. **InputController kaydı:**
   - Yaşam döngüsünün başında (`start()` ya da eşdeğeri) `HostSleepParticipants.shared.register(self, name: "input")` ile kayıt olur, durunca `unregister` eder.
   - İşi kendi girdi kuyruğunda release-all yapmak. Bu, oturum sonu yolu ile idempotenttir: çift bırakma olmaz, eksik bırakma olmaz.
   - Bitince tamamlama geri çağrısını bir kez çağırır.
2. **SystemAudioTap (ya da HostAudio) kaydı:** `audio` adıyla kayıt olur; işi kendi kuyruğunda yakalamayı kapatmak, sonra tamamlama.
3. **Log:** `host_sleep_ack` satırı `input=done|pending audio=done|pending` alanlarını taşır (`HostSleepProgress`, `HostSleep.swift`). Biçim `docs/LOGGING.md`'de belgeli değilse önerilen metni Handoff'a yaz.
4. **Sıra:** katılımcı işleri oturum kuyruğunu beklemeden başlar (`SessionServer.onPower` 1. adım). Tutulan tuş, düğme ya da kalem teması uyku boyunca Mac'te asılı kalmaz (AGENTS.md).
5. **Test:**
   - Saf kısım (`HostSleepProgress` sırası, idempotent tamamlama) için Core testi.
   - Host hedefinin test hedefi yok; kayıt ve bırakma derleme ve cihazla doğrulanır.
6. **Cihazda bakılacak (orkestratör):** `pmset sleepnow` ile uyku. Host logunda `host_sleep_ack … input=done audio=done complete=1` ve `input_release` görülmeli; uyanınca takılı girdi olmamalı.

## Plan

InputController start() registers "input" (releaseOnQueue(.hostSleep) on its own queue, then done); SystemAudioTap init registers "audio" (desired=nil, teardown on tap queue, done). Both unregister in deinit. SessionServer and HostSleep.swift were already correct (snapshot, OnceFlag, logFields); unchanged.

## Handoff

- Commit: 703dfbb2 on task/T-299-sleep-participants (card update in a following commit).
- Files: Input/InputController.swift (register in start, unregister in deinit, releaseOnQueue extracted from releaseInput), Audio/SystemAudioTap.swift (register in init, deinit unregister), this card.
- host_sleep_ack already prints HostSleepProgress.logFields (input=done audio=done); LOGGING.md unchanged.
- Core tests (HostSleepTests) already cover progress order and repeat/unknown idempotence; no new Core logic, so no new tests. check.sh: ALL OK.
- Assumptions: the audio participant clears desired so no rebuild races the sleep; the streamer's later stop is a no-op. Input release is idempotent with the session path. A wedged queue means done is never called and the budget bounds it (field stays pending). The "audio" entry stays registered even with no stream running (cheap no-op).
- Not tested: real sleep. On device: pmset sleepnow, expect host_sleep_ack ... input=done audio=done complete and input_release; no stuck input after wake.
- Review round 1 (Codex high, P1-P3), fixed in a follow-up commit:
  - P1: `InputController` has a queue-confined `sleeping` gate, set by the sleep participant BEFORE its release-all. `gate()` wraps the pipeline output in `deliver` and the `poll` tick: opening events (key/modifier down, mouse/pen down, proximity enter, scroll/pinch begin; `HostSleepInputGate` in Core `HostSleep.swift`) are dropped from any session, counted (`dropped_opens` in `input_sleep_gate_end`), handed to `pipeline.postFailed` (shadow state forgets them) and `pipeline.release(.hostSleep)` runs again so the machine holds nothing. Closing/moving events pass. I did not reuse the machine's pen latch: it covers pen contact only, not keys/buttons/scroll, and `InputPipeline.swift` is outside the card's files. Gate clears on `NSWorkspace.didWakeNotification` (observer in `start`, removed in deinit) or on `sessionStarted` (a session after wake), whichever comes first.
  - P2: after the release the participant drains owed releases with `pipeline.drainOwed` (4 attempts, 50 ms pauses, about 150 ms; same seam as shutdown) and calls `done()` only when nothing is owed; otherwise it logs `input_sleep_owed` and stays pending, so the ack shows `input=pending`.
  - P3: `SystemAudioTap` has a lock-guarded `sleepingUntilNs` (set with `desired = nil` in the participant; cleared by the wake notification; expires after 30 s of awake time as a guard against a lost notification). `start` is ignored while set, `isWanted` is false (so an in-flight build cancels before `AudioDeviceStart`), the setup-changed retry and `reconcile` check `isWanted`. The tap has no retry timers (retries are the streamer's `start` calls), so the flag replaces a generation bump.
  - Tests: Core `HostSleepInputGateTests` (key, pen contact, button after the sleep release never open, nothing held or owed; closing/moving pass). The drain is already covered by the existing `drainOwed` tests in `InputPipelineTests`. The controller wiring (gate placement, wake clearing) and the tap flag are Host-only and untested here. check.sh: ALL OK.
  - Device: `pmset sleepnow` while holding a key/pen; log should show `input_release` cause host_sleep, `host_sleep_ack ... input=done audio=done`, `input_sleep_gate_end` after wake; audio resumes on the next session.
- Review round 2 (Codex high, P1-P2), second follow-up commit:
  - P1: `sessionStarted` no longer clears the input gate. `HostSleepInputGate` is now a pure Core struct (set / `isClosed(atAwakeNs:)` / `wake()` / `expireIfDue(atAwakeNs:)`, shared `windowNs` = 30 s of awake time, `DispatchTime` uptime which does not advance during sleep). Cleared by `didWake` (`input_sleep_gate_end reason=wake`) or expiry (`reason=expired`, checked in `gate()` and the 1 s poll). Tests: set, session start no clear, wake; 10 s still closed; 30 s expires; re-set restarts.
  - P2: `SystemAudioTap` keeps one pending `Request` (latest wins) for a `start` refused in the window, schedules an expiry check (`asyncAfter`), and on wake or expiry restores it as `desired` and reconciles (`audio_capture_resume_after_sleep reason=wake|expired`). `stop(streamID)` and `shutdown` drop the pending request. The tap uses the same Core gate struct and window constant. Host-only wiring, no unit test; check.sh ALL OK.
- Review round 3 (Codex high, two audio P2s), third follow-up commit, `SystemAudioTap` only:
  - The queued sleep teardown now checks under the lock before destroying: it keeps the capture when a request is wanted and the gate has cleared (a post-wake request wins; reconcile owns it), otherwise it tears down (no capture during sleep). `done` is always called.
  - Expiry check is one coalesced `DispatchWorkItem` (`expiryItem`), scheduled only if none is outstanding. Cancelled by `stop` (when nothing is pending), `shutdown` and when the pending start is restored; it reschedules itself if a newer sleep window still has a pending start. Host-only, no unit test; check.sh ALL OK.

## Open questions
