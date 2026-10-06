---
id: T-278
title: Client — yerel imleç v2: tablette konum tahmini (göreli hareket + mutlak kalem/dokunma), host durumuyla uzlaştırma
status: todo
phase: 6
owner: android-client-dev
depends_on: [T-276]
decisions: [0036]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/
  - client-android/app/src/test/kotlin/dev/matebridge/client/
  - docs/decisions/0036-local-cursor.md
  - backlog/tasks/T-278-cursor-prediction.md
---

## Amaç

Karar 0036 v1: imleç host'un bildirdiği konumda çiziliyor (gecikme ≈ RTT + vsync: USB birkaç ms, Wi-Fi ~15–25 ms). v2 (0036 "Tekrar düşünülür"; kullanıcı 2026-10-06 onayladı): tablet, kendi gönderdiği girdiden imlecin nereye gideceğini **hemen** tahmin edip çizer; host'tan gelen `CURSOR_STATE` gerçeği düzeltir. **Protokol değişmez** (tahmin yalnız istemcide; `CURSOR_STATE.host_time_us` + mevcut saat farkı tahmini kullanılır).

## Kabul

1. **Göreli hareket (fare, trackpad, `POINTER_REL`):** host göreli hareketi nokta cinsinden 1:1 uygular, hızlanma yok (MacEvent: "raw movement in whole points"; hız çarpanı tablette uygulanıyor). Tablet gönderdiği her deltayı (nokta, kesir taşıma dahil, gönderim zamanıyla) sınırlı bir halkada tutar. Tahmin = son kabul edilen `CURSOR_STATE` konumu + o durumun host'ta örneklendiği andan **sonra** host'a varmış sayılan deltalar (varış ≈ gönderim + tek yön gecikme tahmini; mevcut PING saat farkı/RTT). Ekran sınırına sıkıştır (`STREAM_CONFIG.width_pt/height_pt`, normalize). Gizli imleçte (`visible=0`) tahmin yapılmaz.
2. **Mutlak (kalem hover/temas, parmak dokunma, `POINTER_ABS`):** konum tam bilinir → imleç hemen o noktaya çizilir; sonraki STATE ile uzlaşır.
3. **Uzlaştırma:** yeni STATE gelince tahmin yeniden hesaplanır; sapma küçükse (≤ ~4 nokta) yumuşak geçiş (1–2 kare), büyükse anında atla (uygulama imleci taşıdı/warp). Hareket durunca tahmin ≤ ~100 ms içinde host konumuna oturur. Tahmin hiçbir zaman girdi yoluna geri beslenmez (yalnız çizim).
4. Oyun modu / `visible=0` / imleç Görüntüde: tahmin kapalı (bugünkü davranış). Geliştirici düğmesi: `--ez dev true --ez cursor_predict false` (varsayılan açık).
5. Ölçüm logu: saniyelik `cursor_stats`'a `pred_err_pt_p50/p95` (tahmin ile sonraki STATE farkı) ve `pred_n`.
6. JVM testleri: delta halkası ve varış kesimi, sınıra sıkıştırma, mutlak giriş, uzlaştırma (küçük/büyük sapma, durunca oturma), gizli/oyunda kapalı.
7. 0036'ya kısa ek (v2 tahmin, protokol değişmeden). `./scripts/check.sh`. Mac'te pencere açma, tablete dokunma.

## Plan

(ajan doldurur)

## Handoff

## Open questions
