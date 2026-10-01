---
id: T-073
title: Tablet — kare izine alma yolu zamanları (soketten okundu, şifre çözüldü, kuyruğa girdi, çözücüye verildi)
status: todo
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

_(Ajan doldurur.)_

## Handoff

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
