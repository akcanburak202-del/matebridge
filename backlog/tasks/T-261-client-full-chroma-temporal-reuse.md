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

Tasarım (yalnız GL/presenter tarafı; `chroma_layout = 0` yolu ve tel biçimi değişmez):

1. **Durum dokusu (GL):** iki RGBA8 doku (ping-pong, tam çözünürlük, tampon koordinatlarında): `R,G,B` = ham Y/Cb/Cr (gösterilen), `A` = referans Y (blok değişmedikçe korunur; kayma olmaz). 2x41 MB, kart bütçesinin üstünde ama sabit (not edilecek). Referans kromu = durum dokusunun Cb/Cr'si; ana kromun referansı = (çift,çift) pikselinin Cb/Cr'si (host `pick`: ana krom = tam krom (2bx,2by); yalnız-ana büyütmede 2x2 bloğa çoğaltıldığı için aynı değer).
2. **Geçişler:** (1) durum geçişi (YUV_target ile ana + varsa yardımcı -> `state[next]`): eşleşmiş karede bugünkü birleştirme (ham değerler yazılır); yalnız-ana karede 2x2 blok karşılaştırması (4 Y vs `A`, ana Cb/Cr vs durumun (çift,çift) Cb/Cr'si, `|d| <= tol` (varsayılan 2, `presentSetReuseTolerance`; negatif = kapalı)): değişmediyse durumun tam kromu + güncel Y (A korunur), değiştiyse ana kromu 2x2'ye çoğalt (bugünkü çıktı) ve A = güncel Y. (2) gösterim geçişi: `state[next]` -> YUV->RGB -> pencere yüzeyi (eglPresentationTimeANDROID, fence, zaman damgaları aynen). Kurulum (shader/FBO) başarısızsa reuse kapanır, mevcut tek geçiş yolu kullanılır (`reuse=0` log).
3. **Geç yardımcı yükseltme (Kotlin):** son çizilen ana görüntü tutulur (retire edilmez, yeni ana çizilince ya da kapanışta bırakılır); yeni ana beklemiyorsa ve bu karenin yardımcısı sonradan geldiyse (`AuxPairing.find`) aynı kare birleştirme ile yeniden çizilir (sunum zamanı 0 = sonraki vsync, etiket -1 = gösterim istatistiği yok), `late_upgrades++`. Karar mantığı saf `LateUpgrade` sınıfında.
4. **Ölçüm:** `reuse_pct` = yalnız-ana (reuse) karelerde referanstan tam renk alan blok oranı: seyrek (her 4. yalnız-ana çizim) küçük 64x40 örnek ızgarası geçişi, sonuç sonraki çizimde fence tamamlandıktan sonra `glReadPixels` ile (bekletmez) okunur. `late_upgrades`. `gl_ms`: GPU zamanlayıcı sorgusu kaldırılır; yerine EGL `RENDERING_COMPLETE_TIME` - takas öncesi CLOCK_MONOTONIC (gönderimden GPU bitişine; destek yoksa çizim çağrısının CPU süresi). LOGGING.md güncellenir.
5. **Saf mantık + JVM testleri:** `ChromaReuse` (blok karşılaştırma kuralı/tolerans, CPU referans durum makinesi: eşleşmiş/yalnız-ana/geç yükseltme; shader'ın satır satır karşılığı), `LateUpgrade`, `AuxPairing.find`; stats biçimi.

Kısıt: tablet/adb yok; GLSL yalnız derleme + CPU referans testiyle doğrulanır, cihaz adımları Handoff'ta.

## Handoff

## Open questions
