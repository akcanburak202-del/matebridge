---
id: T-325
title: Host — StreamCoordinator oturum kapanışında takıldı; posta kutusu taştı ve her yeni oturum hemen kapandı (kullanıcı Mac'i zorla kapattı)
status: review
phase: 7
owner: mac-host-dev
depends_on: []
decisions: []
files:
  - host-mac/Sources/MateBridgeHost/Session/StreamCoordinator.swift
  - host-mac/Sources/MateBridgeHost/Session/SessionServer.swift
  - host-mac/Sources/MateBridgeHost/Video/
  - host-mac/Sources/MateBridgeCore/Video/
  - host-mac/Sources/MateBridgeCore/Session/
  - host-mac/Tests/MateBridgeCoreTests/
  - host-mac/Sources/MateBridgeApp/main.swift  # (orchestrator)
  - host-mac/Sources/MateBridgeHost/Input/InputController.swift  # (orchestrator, T-325 review)
  - host-mac/Sources/MateBridgeCore/Input/HeldInputMirror.swift  # (orchestrator, T-325 review)
  - backlog/tasks/T-325-coordinator-stall.md
---

## Amaç

2026-10-08 ~19:50 (host `7dda2489`, release; Wi-Fi). Kanıt `~/Library/Logs/MateBridge/host.log`:
1. Oyun akışı sırasında (60 fps, ~62 Mbps) kontrol bağlantısında yeniden gönderimler oldu (`retx_pkts_delta` 19 ve 33). Tablet oturumu BYE ile kapattı: `bye_received conn=131`, `audio_capture_stopped`.
2. Ondan sonra koordinatörün saniyelik satırları (`ev=stats`, `ev=tcp`, `ev=latency`) **tamamen durdu**. `display_parked` ya da `display_teardown` satırı yok. Koordinatör `onSessionEnded` (ya da hemen sonrası) içinde takıldı.
3. 18 sn sonra yeni el sıkışma geldi: `E net ev=event_overflow` (mailbox, kapasite 16) → `onOverflow` → `sessions_ended_by_host` → `shutdown`. Bu her yeni bağlantıda tekrarlandı (9 kez); kullanıcı Mac'i güç tuşuyla kapattı.

Şüpheli: `stopConsumer` (`StreamCoordinator.swift` ~1179) `.sender` durumunda önce `await sender.stop()` (görevi iptal edip bitmesini bekliyor), **sonra** `link.cancel()` çağırıyor. Ağ tıkalıyken ya da kuyrukta beklerken iptale yanıt vermeyen bir await varsa kapanış sonsuza kadar bekler. T-313'ün `VideoSender` değişikliği davranışı değiştirmedi; sorun büyük olasılıkla eskiden beri var, ama kanıtlanmadı.

## Kabul

1. **Belirsiz beklemeler:** `onSessionEnded`, `park`, `destroyPipeline`, `stopConsumer`, `onShutdown` ve pipeline durdurma yolundaki her `await` incelenir. Ağ tıkanması, iptale duyarsız `AsyncStream`/continuation, VT tamamlanmama ya da SCK durdurma beklemesiyle sonsuza kadar kalabilecekler listelenir; bulgular Handoff'ta, dosya:satırla.
2. **Kapanış sırası:** bağlantı kaynağı önce kapatılır (`link.cancel()`, bloklu yazmayı çözer), sonra gönderici beklenir. Her bekleme süreyle sınırlanır (ör. 2 sn); süre aşılırsa `ev=consumer_stop_timeout` loglanır ve devam edilir.
3. **Bekçi:** koordinatör bir olayı N saniyeden (ör. 3 sn) uzun işlerse `E ev=coordinator_stall event=<tür> ms=` loglanır (olay türü, içerik değil). Takılma 10 sn'yi geçerse bir kurtarma yolu çalışır: en kötü durumda süreç kendini temiz kapatır (girdi release-all, BYE) ve yeniden başlar. Hangi yolun seçildiği ve gerekçesi Handoff'a; T-202 (LaunchAgent) yoksa güvenli seçenek önerilir. **Girdi asla takılı kalmaz.**
4. **Taşma döngüsü:** posta kutusu taştıktan sonra her yeni oturumun hemen kapanması döngüsü kırılır. Taşma bir kez olur, ardından toparlanma gelir.
5. **Testler:** saf kısımlar (zaman aşımı, bekçi durum makinesi) Core'da. Mümkünse sahte bir transport ile "yazma hiç tamamlanmaz" senaryosunda `stopConsumer`'ın süre içinde döndüğünü gösteren bir test.

## Plan

1. Bekleme envanteri (Handoff). 2. Core: `BoundedWait` (süreli bekleme, zamanlayıcı dispatch kuyruğunda) ve `CoordinatorWatchdog` (saf durum makinesi: 3 sn uyarı, 10 sn oturumları bitir, 30 sn yeniden başlat). 3. `stopConsumer`: önce `link.cancel()`, sonra sınırlı bekleme. 4. `VideoPipeline.teardown`: capture ve encoder durdurma adımları ayrı ayrı sınırlı. 5. Koordinatör: her olay bekçiye bildirilir, bekçi ayrı kuyrukta. 6. Taşma sonrası zorlanmış `sessionEnded`/`shutdown` yalnız bir kez korunur. 7. Testler Core'da.

## Handoff

Dal `task/T-325-coordinator-stall`, commit: bkz. `git log -1` (T-325). check.sh: ALL OK.

**Kabul 1: sınırsız beklemeler (dosya:satır, düzeltme öncesi davranış)**

Kanıt analizi (host.log, conn=131): BYE'dan sonra `audio_capture_stopped` var, `display_parked` ve `display_teardown` yok. `onSessionEnded` -> `stopConsumer` -> `perform(.park)` -> `park()` -> `stopKeepingDisplay()` zinciri `display_parked` satırından önce takıldı. Hangi çağrının takıldığı kanıtlanamadı (log yeterince ayrıntılı değil). Adaylar:

1. `ScreenCapture.swift:108` `try? await s?.stopCapture()`: SCStream durdurma, zaman aşımı yok. En olası aday (park yolunda `VideoPipeline.teardown` içindeki ilk bekleme).
2. `HEVCEncoder.swift:931-934` `shutdown()` -> `withCheckedContinuation`; owner kuyruğundaki `VTCompressionSessionCompleteFrames` (`HEVCEncoder.swift:736`) dönmezse continuation hiç devam etmez.
3. `VideoSender.swift:97-101` `stop()` -> `await t?.value`. Döngü iptale duyarlı (`AsyncStream.next` iptalde nil döner, `SocketVideoTransport.send` bloklamaz), tek başına takılması beklenmez; yine de sınırsızdı.
4. `StreamCoordinator.swift` `stopConsumer` drain dalı (`await task.value / auxTask.value`): `VideoFrameQueue.next` iptale duyarlı, düşük risk, yine sınırsızdı.
5. `StreamCoordinator.swift:982` `try await p.start()` (sanal ekran oluşturma, `ScreenCapture.swift:94` `startCapture`): başlatma beklemeleri sınırsız. Meşru olarak birkaç sn sürebildiği için süre sınırı konmadı; yalnız bekçi kapsıyor.
6. `sleep(until:)` / `onPipelineFailed` geri çekilme uykusu: bilinçli ama döngüyü tutar (bekçi saymaz: pause/resume).

Taşma döngüsü: takılı döngü varken her oturum `sessionStarted`/`videoAttached` bırakır. Taşmada `post`, zorlanmış `sessionEnded` ve `shutdown` olaylarını her seferinde geri koyuyordu; bunlar tavana sayıldığı için birikip her yeni oturumu taşırıyordu (log: 9 taşma). Asıl neden takılı döngü, birikim ikinci etken.

**Yapılan**
- `StreamCoordinator.stopConsumer`: önce `link.cancel()`, sonra `BoundedWait` 2 sn; aşılırsa `E net ev=consumer_stop_timeout consumer=sender|drain`.
- `VideoPipeline.teardown`: capture durdurma ve encoder kapatma ayrı ayrı 3 sn; aşılırsa `E video ev=pipeline_stop_timeout step=capture|encoder`, sanal ekran yine bırakılır. Takılan çağrı arkada kalır (sızıntı kabul edildi).
- Bekçi (`CoordinatorWatchdog`, ayrı dispatch kuyruğunda, 1 sn): 3 sn `E net ev=coordinator_stall event=<tür> ms=`; 10 sn `coordinator_stall_recover action=end_sessions` -> `onOverflow` (= `SessionServer.endSessions`: girdi release-all + BYE, koordinatörden bağımsız); 30 sn `action=restart` -> oturumlar yine bitirilir, sonra `onStallRestart` (bağlı değilse varsayılan: .app paketiyse 3 sn sonra `open -n` ile yeniden başlatma, ardından `exit(75)`; paket değilse yalnız çıkış). Olay biterse `W net ev=coordinator_stall_over`. Geri çekilme uykuları sayılmaz.
- Taşma: zorlanmış `sessionEnded` ve `shutdown` taşmada yalnız bir kez geri konur.
- Testler `Tests/MateBridgeCoreTests/Session/CoordinatorStallTests.swift`: BoundedWait (biter, hiç dönmez, geç tamamlanma, sıfır süre, takılı transport ile `VideoSender.stop`), Watchdog (kademeler, uzun boşluk, pause, uç durumlar). `StreamCoordinator` Host hedefinde olduğundan `stopConsumer` ve taşma kodu birim testsiz.

**Kurtarma yolu seçimi:** 10 sn'de yalnız oturumlar biter (geri alınabilir, girdi hemen serbest kalır, tablet yeniden bağlanır). Süreç yeniden başlatma 30 sn'de: meşru en uzun beklemeler (sanal ekran oluşturma) birkaç sn, yanlış pozitifin maliyeti bir oturum kesintisi. T-202 (LaunchAgent) yok, bu yüzden `open -n` ile kendi kendini başlatma eklendi. Bu kullanıcıya görünen bir davranış ve donanımda denenmedi. Daha güvenli alternatif: `main.swift`'te `onStallRestart` ile `NSApp.terminate` bağlamak (`applicationWillTerminate` girdiyi bırakır); `main.swift` kapsam dışı olduğu için yapılmadı.

**Doğrulanmadı (host çalıştırılmadı, tablet kullanılmadı)**
- Takılma yeniden üretilmedi; gerçek neden (aday 1 ya da 2) bilinmiyor. Tekrarlarsa `pipeline_stop_timeout step=...` hangisi olduğunu söyler.
- `defaultStallRestart` (open -n + exit) hiç çalıştırılmadı; paketli uygulamada eşiği düşürerek ya da `onStallRestart` tetikleyerek denenmeli. TCC kimliği aynı paket olduğundan korunmalı.
- `endSessions` `queue.async` olduğundan `exit(75)` onu yarıda kesebilir; 10. sn'de zaten çalışmış olmalı (30. sn'deki ikinci çağrı yalnız yedek).

**Review round 1 (Codex high: P1 + P2), additional commit**
- P1(a): from the 10 s step the watchdog calls `onRefuseSessions(true)` -> `SessionServer.setRefusingSessions`; `acceptControl`/`acceptVideo` cancel new connections (`connection_refused reason=coordinator_stalled`, `sessions_refused state=on`). Lifted when the stalled event ends, never after a restart was requested.
- P1(b): `main.swift` `onStallRestart` -> `StallRestart.run` (Core): `input.shutdown()` (release-all + bounded drain of owed releases, idempotent) on a background queue, waited at most 1.5 s, logs `E net ev=stall_restart input=done|pending`. I reused `InputController.shutdown()` (the quit path, same drain) instead of the sleep participant; both share `releaseOnQueue`/`drainOwed`.
- P1(c): then `NSApp.terminate` via the main queue (`applicationWillTerminate` runs `input.shutdown` again, server stop, coordinator shutdown); if the process is still alive after 4 s, `exit(75)` (`terminate=timeout` logged). The old `exit(75)` default in the coordinator was removed; without a hook the coordinator only ends sessions.
- P1(d): the relaunch helper (`/bin/sh`, started before the terminate) polls `kill -0 <old pid>` once a second and runs `open -n <bundle>` only after the old pid is gone; after 25 s of waiting it gives up and opens nothing, so there is never a second instance next to the old one. Only for `.app` bundles.
- P2: `AbandonedStops` (Core, process-wide). `VideoPipeline.boundedStop` registers a timed-out capture/encoder stop, logs `pipeline_stop_timeout` and `pipeline_stop_abandoned step= n=`, and clears it when the stuck call returns late. The watchdog poll escalates through the same restart path at 2 open stops or one older than 60 s (`coordinator_stall_recover action=restart reason=stop_abandoned`). A restart is requested at most once per process.
- Tests: `StallRestartTests.swift` (order release -> relaunch -> terminate -> exit, hung input still restarts with `input=pending`, relaunch waits for the old pid, abandoned-stop thresholds and late completion, session-refusal steps). check.sh: ALL OK.
- Unverified on hardware: the whole restart path (terminate, relaunch helper, TCC identity after relaunch) and `sessions_refused` on a real tablet reconnect. A wedged input queue is covered only by the 1.5 s bound (`input=pending`).

**Review round 2 (Codex high: P1 + 2x P2), additional commit**
- P1, emergency release: `HeldInputMirror` (Core/Input) lists keys, modifiers, mouse buttons, pen contact and proximity, scroll and magnify gestures. `InputController.post` records opens before the post (a wedged post may have landed) and replays the accepted prefix after it, under `heldLock` (never held while posting). `InputController.emergencyRelease()` plans the closing events (pen up with zero pressure, leave, mouse ups, gesture ends, key-ups, modifier-ups with cleared flags) and posts them through a fresh `CGEventPoster` from the caller's thread; it returns nil if posting failed. `StallRestart.run`: normal `input.shutdown()` bounded 1.5 s; if it did not finish, the emergency release runs on its own thread, bounded 1 s, and logs `input=emergency released=n`. If that fails or hangs: `input=unreleased`, NO relaunch/terminate/exit, outcome `.inputUnreleased`; the host stays up with sessions refused (a restart is never retried, `restartRequested` stays set).
- P2, refusal race: refusal/restart flags now live in `CoordinatorWatchdog`, and every transition plus its hook call (`onRefuseSessions`, `onOverflow`) happens inside `watchdogLock`, also the end of an event and `liftRefusal()` (any healthy completion lifts, unless a restart is requested). So a poll cannot apply a step after the event it saw has ended; no separate sequence ids were needed because the state change and its side effect are one critical section. Restart itself runs outside the lock. Core tests cover the interleavings.
- P2, wrapped age: `AbandonedStops.escalation` treats a stop recorded after `nowUs` was sampled as age 0. Test added.
- Tests: `HeldInputMirrorTests`, extended `StallRestartTests`. check.sh: ALL OK. Unverified on hardware: the emergency post path itself (`CGEventPoster` from a non-input thread) and that a fresh poster behaves like the controller's.

**Review round 3 (Codex: 3x P1 on the exit path), rule change (orchestrator decision)**
Instead of patching "exit safely while input may be held" again, the rule is now: **restart only when nothing is held, confirmed.** `StallRestartDecision.decide` (Core): restart only if the release completed within 1.5 s AND reports zero owed releases AND the held-input mirror is empty. Otherwise `E net ev=stall_restart outcome=skipped reason=input_wedged|owed|input_held`, nothing is terminated or exited, sessions stay refused, and the coordinator retries every 5 s (`StallRestart.retryIntervalUs`, a later successful release then allows the restart). A retry joins a still-hanging release (`ReleaseAttempt`) instead of piling up blocked threads.
- `InputController.shutdown()` now returns the owed count (and drains again when called after stopping, so a retry can succeed); `stallRelease()` returns `InputReleaseReport(owed, mirrorEmpty)`.
- The emergency release is best effort only: tried when the release did not complete, gated on a fresh Accessibility check (`permission.isTrusted()`), never clears the mirror, never confirms, never permits an exit (logged `input=emergency released=n confirmed=0`).
- Mirror hygiene: opens are recorded before a post (a wedged post may have landed) but the snapshot is restored after the post and only the accepted prefix is replayed, so an open that failed does not stay "held" forever (that would block every later restart).
- Stall gate: `InputController.setStallGate(_:)`, switched by the same `onRefuseSessions` hook as the session refusal (10 s step on, lifted with the refusal, never lifted after a restart request). `gate()` drops opening events exactly as the T-299 sleep gate does (shared `HostSleepInputGate.split`), closing events pass; `ev=input_stall_gate state=on|off`.
- Tests (Core): decision table, outcomes with owed/held mirror/wedged queue/failed emergency, retry joining a hanging release, gate split (opens dropped, closes pass), refusal step/lift. check.sh: ALL OK.
- Unverified on hardware: the whole restart path, and the 5 s retry loop while sessions are refused. Note: once `stallRelease` ran, input stays stopped until the process restarts (no recovery of input without restart).

**Review round 4 (two P2)**
- The emergency release now runs through `EmergencyAttempt` (a `SingleFlight`, like `ReleaseAttempt`): at most one outstanding, later retries join the hung one instead of starting another worker (test: a hung emergency body is started once across retries).
- `InputController.setStallGate` logs with neutral ids (0, 0): it runs on the watchdog thread and no longer reads the queue-confined session ids. check.sh: ALL OK.

## Open questions

- (Resolved in review round 1) `main.swift` was added with the orchestrator's permission.
- `p.start()` (sanal ekran/startCapture) beklemeleri sınırsız bırakıldı; yalnız bekçi kapsıyor.
