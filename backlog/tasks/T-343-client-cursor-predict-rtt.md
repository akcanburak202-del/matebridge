---
id: T-343
title: İstemci — yerel imleç tahmini uzun hatlarda (RTT 250+ ms) geri sıçramasın
status: todo
phase: 7
owner: android-client-dev
depends_on: []
decisions: [0036, 0038]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/cursor/
  - client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt
  - client-android/app/src/test/
  - backlog/tasks/T-343-client-cursor-predict-rtt.md
---

## Amaç

Karar 0036 ek (2026-10-12). Uzak oturumda (Tailscale aktarma, RTT 230–320 ms) trackpad imleci ileri gidip geri sıçrıyor. Ölçüm (`MB/render cursor_stats`, 2026-10-12 22:39):

- Hareket başında: `pred_err_pt_p50=85.78 p95=434.83`; `hold_err_pt_p50=48.41`.
- Sonraki saniyeler: pred hâlâ hold'dan büyük ya da eşit.

`CursorPredictor` sabitleri LAN içindi: `SETTLE_US` 100 ms, `MAX_ONE_WAY_US` 100 ms, `MAX_STATE_AGE_US` 250 ms, `KEEP_US` 500 ms. Deltalar host durumu dönmeden "yerleşmiş" sayılıyor ve tahminden düşüyor; tek yön tavanı varış zamanlarını yanlış hesaplıyor.

## Kapsam

1. **RTT'ye bağlı süreler:** bu süreler ölçülen RTT'den türetilsin (oturumun mevcut RTT ölçümünden; `ev=net rtt_ms_p50_95_max` aynı kaynak). Taban = bugünkü sabitler; LAN'da (RTT ≲ 50 ms) davranış bit bit aynı. Makul üst sınır koy, örneğin RTT 1 s; daha uzun hatta tahmin askıya alınıp v1 çizimine (host konumu) düşsün.
2. **Uzlaştırma:** uzun hatta büyük düzeltmelerde anlık atlama yerine kısa erime gerekiyorsa gerekçesiyle ekle; yalnız ölçüm ya da benzetim destekliyorsa.
3. **Değişmeyenler:** protokol, host, girdi yolu. Askıya alma kuralları (kalem / `POINTER_ABS` 300 ms) aynı kalır.

## Kabul

- Birim testi (benzetim):
  - RTT 250 ms, ±30 ms titreşim, 120 Hz göreli hareket, 15 fps durum güncellemesi: `pred_err` p50 ve p95 değerleri `hold_err`'den belirgin küçük. Hareket durunca tahmin RTT + küçük pay içinde host konumuna oturur.
  - RTT 15 ms'de çıktılar bugünküyle aynı (regresyon testi).
- `./scripts/check.sh` geçer.
- Cihaz testi orkestratörde (uzak oturum, `cursor_stats` pred/hold).

## Plan

## Handoff

## Açık sorular
