---
id: T-252
title: Client — on queue overflow, decode the backlog fast and show only the newest frame instead of flushing + keyframe request
status: ready
phase: 6
owner: android-client-dev
depends_on: [T-251]
decisions: [0021]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/
  - client-android/app/src/test/kotlin/dev/matebridge/client/
  - backlog/tasks/T-252-client-catch-up-instead-of-flush.md
---

## Amaç

Bugün `FrameQueue` bekleyen kare sayısı sınırı aşınca (120 fps'te 8, `depthForFps`) tüm bekleyenleri atıyor, anahtar kare bekliyor ve KEYFRAME_REQUEST gönderiyor (`video/FrameQueue.kt` ~161–183). Anahtar kare büyük bir patlama: Wi-Fi'da ağı yeniden tıkıyor (T-121/T-122 "keyframe fırtınası"), görüntü IDR gelene kadar donuyor. T-248/T-249: çözücü 2800×1840'ta ~300–356 fps çözüyor (8 kare ≈ 25 ms), IDR karesi ~+15 ms. Kullanıcı onayladı (2026-10-05): "takılma sonrası hızlıca yetiş".

## Bağlam

- Yeni davranış (taslak; ajan kodu okuyup Plan'da kesinleştirir): kareler referans zinciri bozulmadan çözücüye verilmeye devam eder; sunum tarafı, yetişme sırasında yalnız en yeni hazır kareyi gösterir, eskileri `releaseOutputBuffer(render=false)` ile bırakır. Yetişme bitince pacer normal kilide döner (re-anchor; T-211/T-208 yapısı).
- Anahtar kare isteği yalnız gerçek bozulmada kalır (eksik kare / sıra boşluğu / çözücü hatası); salt birikme için istenmez. Birikme yetişemeyecek kadar büyürse (ör. > ~0,5 s ya da sınırlı bellek) bugünkü atma + istek yolu emniyet olarak kalır. Kuyruk sınırlı kalır (AGENTS.md: bounded queues).
- Ölçüm/tanı: `ev=catch_up frames= ms=` olayı ve `ev=stats` sayaçları (yetişme sayısı, atlanan sunum, istenmeyen IDR sayısı). Mevcut `overflows`, `kf_req` alanları korunur.
- Geri alma düğmesi: `--ez dev true --ez catch_up false` eski davranış (A/B için).
- Girdi tarafına dokunma. Tel biçimi değişmez.

## Kabul kriterleri

- [ ] Birikmede KEYFRAME_REQUEST gönderilmez; kareler çözülür, yalnız en yenisi gösterilir; birim testleri (FrameQueue/sunum karar mantığı) bunu kapsar.
- [ ] Emniyet sınırı aşılınca eski yol çalışır; testli.
- [ ] `./scripts/check.sh` geçer.
- [ ] Handoff: Wi-Fi ve USB'de cihaz doğrulama adımları (ör. Wi-Fi'da tam ekran geçişleri, `kf_req` ve donma süresinin karşılaştırması, `catch_up false` A/B).

## Plan

## Handoff

## Open questions
