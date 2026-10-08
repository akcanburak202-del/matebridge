---
id: T-305
title: Kalem yolu maliyeti — örnek başına host CPU (~0,6 ms), her örneğin ayrı kayıt olması (max_batch=1), kontrol bağlantısında kuyruk (RTT 108 ms)
status: done
phase: 7
owner: orchestrator
depends_on: [T-296]
decisions: []
files:
  - docs/research/2026-10-08-pen-path.md
  - docs/NOTES.md
  - backlog/tasks/T-305-pen-path-cost.md
---

## Amaç

T-296 S3 (`docs/research/2026-10-08-baseline.md`). Sentetik kalem (~980 örnek/s) sırasında:
- host %60 CPU, WindowServer %32;
- tablet ana iş parçacığı %43 (3.800 uyanma/s), `mb-ctl-write` 1.680 uyanma/s;
- `max_batch=1`: her PEN mesajı tek örnek, tek kayıt;
- kontrol RTT 108 ms, kalem yaşı ~55 ms; `cap_dec` p50 60 ms.

Gerçek kalem hızı bilinmiyor; loglarda gerçek kalem verisi yok. Gerçek hız 240 Hz ise etki ~¼, ama örnek başına maliyet ve kayıt başına gönderim yine geçerli.

## Yöntem

1. **Gerçek kalem hızı (kullanıcıyla, 1 dk çizim):**
   - host `input_age pen_n`, tablet `MB/input pen_samples`/`pen_msgs`/`max_batch`;
   - `getevent -lt` ile donanım rapor hızı.
2. **Host profili (kullanıcısız):** sentetik vuruş sırasında `sample MateBridgeApp 10` ve `sample WindowServer`. Örnek başına iş nereye gidiyor? Adaylar:
   - imleç sorgusu (T-103);
   - kalem başına iki CGEvent (fare sürükleme + tablet);
   - log ve istatistik;
   - oturum kuyruğu geçişleri.
3. **İstemci tarafı:**
   - PEN mesajı birden çok örnek taşıyabiliyor (`PEN.count`). Hazır bekleyen örnekler gönderim anında tek mesajda birleşirse (gecikme eklemeden, yalnız kuyrukta zaten bekleyenler) kayıt sayısı düşer.
   - Ana iş parçacığındaki 3.800 uyanma/s'nin kaynağı: tamponsuz dağıtım mı, olay başına iş mi?
4. **Kontrol bağlantısı:** PING/PONG'un PEN kayıtlarının arkasında beklemesi saat farkı tahminini (`clock_unc`) bozuyor. Etkisi ölçülür.
5. **Çıktı:** `docs/research/2026-10-08-pen-path.md`. Bulgular uygulama kartlarına dönüşür (protokol değişikliği gerekirse orkestratör).

## Kabul

1. Gerçek ve sentetik hızda örnek başına host, WindowServer ve tablet maliyeti tablosu.
2. En az bir uygulanabilir azaltma önerisi, kanıtıyla; ya da "değmez" kararı, gerekçesiyle.

## Plan

## Handoff

2026-10-08: `docs/research/2026-10-08-pen-path.md`. Gerçek kalem 360/s; asıl maliyet yerel imleç örneklemesi (→ T-309) ve debug host derlemesi (→ `bundle-host.sh` varsayılanı release, 0037 eki). Örnek birleştirme düşük öncelikli.

## Open questions
