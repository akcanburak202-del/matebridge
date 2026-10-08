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

## Open questions

- `main.swift` dosya listesinde yok: `onStallRestart` bağlanmadı. Bağlanacaksa kapsam genişletilmeli.
- `p.start()` (sanal ekran/startCapture) beklemeleri sınırsız bırakıldı; yalnız bekçi kapsıyor.
