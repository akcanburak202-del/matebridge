---
id: T-073
title: Tablet — kare izine alma yolu zamanları (soketten okundu, şifre çözüldü, kuyruğa girdi, çözücüye verildi)
status: done
phase: 5
owner: android-client-dev
depends_on: [T-069]
decisions: []
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/
  - client-android/app/src/main/kotlin/dev/matebridge/client/session/
  - client-android/app/src/main/kotlin/dev/matebridge/client/security/
  - client-android/app/src/test/
  - backlog/tasks/T-073-client-trace-receive-path.md
---

## Amaç

NOTES 2026-10-01 ~12:40: tablette ara sıra ~40 ms'lik varış boşlukları (`net_p99_us` 40–44 ms) var; host tarafında (`ev=latency` `cap_to_sent` max ≤ 9 ms) sıçrama yok. Boşluk USB/adb tünelinde mi, tablette okuma/şifre çözme/kuyrukta mı, çözücüye verme beklemesinde mi — kare başına bilmek gerekiyor. Host kare başına CSV'si (`MATEBRIDGE_LAT_TRACE=1` → `~/Library/Logs/MateBridge/latency.csv`, `capture_us` = teldeki `capture_time_us`) ile `capture_us` üzerinden eşleştirilecek.

## Kabul kriterleri

- [ ] T-069 izine (`--ez pace_trace true`) sütunlar: `recv_ns` (VIDEO_FRAME kaydının son baytı soketten okundu), `decrypted_ns` (AES-GCM açıldı / çerçeve ayrıştırıldı), `queued_ns` (`FrameQueue.offer`), `input_ns` (`queueInputBuffer`), ayrıca `bytes` (kare boyutu). Sunum satırı ile aynı satırda (seq/pts ile birleştirilir); kayıp/atılan kareler için de satır (action=`queue_drop` vb.) olsun ki boşluğun nerede doğduğu görülsün.
- [ ] Ek yük ihmal edilebilir (tahsis yok). İz kapalıyken davranış ve maliyet aynı.
- [ ] Test (sütunlar, halka). `./scripts/check.sh` geçiyor.

## Plan

PaceTrace'e ikinci bir halka (alım halkası, slot = frameSeq % kapasite, tahsissiz) eklenir. Video bağlantı iş parçacığı `onRecv` ile recv_ns (read() dönüşü) ve decrypted_ns (next() sonrası) yazar; `FrameQueue.offer` kaydın akıbetini (`onRxAction`) ve queued_ns'i; kodek giriş iş parçacığı `onInput` ile input_ns'i. CSV yazarken sunum satırları seq (= codec pts = frameSeq) ile birleştirilir; hiç sunulmayan kareler (queue_drop, gate_drop, pending_drop, reset_drop, config, hâlâ kuyrukta) kendi satırını alır, `action` sütunu alım akıbetini taşır. Video iş parçacığı izi `PaceTrace.active` (VideoRenderer.paceTrace ayarlayıcısı set eder) üzerinden bulur, böylece MainActivity'ye dokunulmaz. İz kapalıyken maliyet: kare başına bir volatile okuma.

## Handoff

- **Commit:** (aşağıda rapor edilen SHA)
- **Dokunulan dosyalar:** video/PaceTrace.kt, video/FrameQueue.kt, video/VideoRenderer.kt, session/SessionController.kt, test/.../PaceTraceTest.kt, bu kart
- **Varsayımlar:** recv_ns = ilgili kaydın son baytını getiren `input.read()`'in dönüş zamanı (aynı okumada gelen birkaç kayıt aynı recv_ns'i paylaşır). decrypted_ns = `decoder.next()` dönüşü (AES-GCM + ayrıştırma). input_ns = `queueInputBuffer` sonrası. Hepsi System.nanoTime, sunum sütunlarıyla aynı saat. Sütunlar mevcut 24'ün sonuna eklendi: `recv_ns,decrypted_ns,queued_ns,input_ns,bytes,rx_action` (rx_action: received/queued/config/queue_drop/pending_drop/gate_drop/reset_drop). Host `latency.csv` ile `capture_us` üzerinden eşleşir. Global `PaceTrace.active` kullanıldı (MainActivity files listesinde değil).
- **Test edilmeyenler / cihazda doğrulanacaklar:** `--ez pace_trace true` ile çalıştır, pace_trace.csv'yi çek: yeni sütunlar dolu mu, recv_ns farkları ile 40 ms boşlukların nerede (recv, decrypted, queued, input) doğduğu; kayıp kareler için ayrı satır var mı; iz kapalıyken akış değişmedi mi.
- **Açık sorular:**
