---
id: T-325
title: Host — StreamCoordinator oturum kapanışında takıldı; posta kutusu taştı ve her yeni oturum hemen kapandı (kullanıcı Mac'i zorla kapattı)
status: todo
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

## Handoff

## Open questions
