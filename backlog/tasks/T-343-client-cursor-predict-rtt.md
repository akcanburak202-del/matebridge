---
id: T-343
title: İstemci — yerel imleç tahmini uzun hatlarda (RTT 250+ ms) geri sıçramasın
status: review
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

Sabitler zaten `oneWayUs` (en iyi RTT / 2) ile besleniyor; sorun tavanlar ve yerleşme süresiydi. Çözüm yalnız `CursorPredictor` içinde, tek yön gecikmeden (ow) türetme:
- `SETTLE_US` -> `max(100 ms, 2*ow + 50 ms)` (bir tur + bir durum aralığı). Çizim anında delta yaşı ~2*ow olduğundan, 100 ms'de delta düşüp imleç geri sıçrıyordu (ölçüm anındaki `pred_err` bunu göstermiyor: orada yaş <= ow).
- `KEEP_US` -> `max(500 ms, settle + 400 ms)`; `MAX_STATE_AGE_US` -> `max(250 ms, 3*ow)`.
- `MAX_ONE_WAY_US` 100 ms -> 500 ms (RTT 1 s). Daha uzun hatta tahmin askıda, v1 (host konumu).
- LAN (ow <= 25 ms) için hepsi eski değerlerle aynı (regresyon testi).
- Madde 2 (erime): eklenmedi; benzetimde en büyük geri adım LAN'daki gibi ~7 pt, ölçüm gerektirmiyor.

## Handoff

- Branch `task/T-343-cursor-predict-rtt`, commit SHA: `git log -1` (orkestratöre raporlandı).
- Dosyalar: `client-android/.../cursor/CursorPredictor.kt`, yeni test `CursorPredictorRttTest.kt` (ağ benzetimi: RTT 250 ±30 ms, 120 Hz göreli hareket, 15 fps durum; LAN regresyon; RTT 1.4 s tavan).
- Benzetim (çizim anı; niyet = host + yoldaki delta): eski kod p50 25 pt / p95 173 pt (hold 40 / 258); yeni p50 2.3 / p95 30. Ölçüm anı `pred_err`: p50 2.7 / p95 15 (hold 31 / 70).
- Varsayım: `oneWayUs` = en iyi RTT / 2 (MainActivity, değişmedi). Protokol/host/girdi yolu değişmedi.
- Cihazda bakılacak (uzak oturum, RTT 230-320): `MB/render cursor_stats` içinde `pred_err_pt_p50/p95` hold'dan belirgin küçük; trackpad imleci hareket sırasında geri sıçramıyor, durunca ~RTT sonra host konumuna oturuyor. LAN'da davranış değişmemeli. Gerçek cihazda test edilmedi.

## Açık sorular
