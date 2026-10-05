---
id: T-261
title: Client — full chroma without flicker: keep the last full colour in unchanged blocks when the aux frame is late, upgrade late pairs
status: ready
phase: 6
owner: android-client-dev
depends_on: [T-259]
decisions: [0034]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/
  - client-android/app/src/main/cpp/
  - client-android/app/src/test/kotlin/dev/matebridge/client/
  - docs/LOGGING.md
  - backlog/tasks/T-261-client-full-chroma-temporal-reuse.md
---

## Amaç

İlk cihaz testi (NOTES 2026-10-06 ~00:35): Wi-Fi'da yardımcı kare ana karenin slotuna %57–92 yetişiyor; yetişmeyen karede yalnız-ana (4:2:0) gösteriliyor → durağan Apple Music ikonu tam renk ↔ 4:2:0 arasında titriyor. Kullanıcı seçeneği **B** seçti (2026-10-06): gecikme eklemeden, değişmeyen bölgelerde son tam rengi koru.

## Bağlam

- **Referans durumu (GL tarafı):** son eşleşmiş (ana+yardımcı) karenin tam çözünürlüklü Cb/Cr'si bir dokuda (ör. RG8 2800×1840) ve o karenin ana görüntüsünün blok başına değerleri (Y 2×2 + ana Cb/Cr `pick` örneği; ya da doğrudan önceki ana Y/UV dokuları) saklanır.
- **Yalnız-ana karede:** 2×2 blok başına ana karenin değerleri referansla aynıysa (tolerans: |ΔY| ≤ 2, |ΔC| ≤ 2 — T-253 netleştirme trenleri durağan bölgeleri hafifçe değiştirir; toleransı birim testi + cihazda doğrula) **referanstaki tam renk** kullanılır, değilse bugünkü yalnız-ana büyütme. Paired karede bugünkü birleştirme + referans güncellenir.
- **Geç gelen yardımcı:** yardımcı N, ana N gösterildikten sonra gelirse yine çözülür, ana N ile birleşip referansı günceller; o arada daha yeni ana kare yoksa (durağan ekran) aynı kare tam renkle **yeniden sunulur** (bir sonraki vsync). Böylece hareket bitince ekran ~1 kare içinde tam renge oturur.
- Bellek/GPU bütçesi: ek dokular ~15–20 MB; geçiş ~1 ms hedef. Sunum düzeni (T-256: duran kuyruk yok, `eglPresentationTimeANDROID`) korunur.
- **Ölçüm:** `ev=stats`'a `reuse_pct` (yalnız-ana karelerde referanstan tam renk alan blok oranı, örneklemeli ya da kare başına bayrak), `late_upgrades`; `gl_ms` şu an 0,01 gösteriyor (GPU zamanlayıcı sorgusu yanlış): `EXT_disjoint_timer_query` ile düzelt ya da CPU tarafı çizim süresine geç ve LOGGING'de açıkla.
- `chroma_layout = 0` yolu ve tel biçimi değişmez.

## Kabul kriterleri

- [ ] Saf mantık JVM testli (blok karşılaştırma kuralı/toleransı CPU referans uygulamasıyla, geç yardımcı yükseltme kararı).
- [ ] `./scripts/check.sh` geçer.
- [ ] Handoff: cihazda doğrulama (Wi-Fi Günlük 60: durağan ikonlar kaydırma sırasında titremiyor; `reuse_pct`, `late_upgrades`, `aux_paired_pct`; gecikme değişmiyor).

## Plan

## Handoff

## Open questions
