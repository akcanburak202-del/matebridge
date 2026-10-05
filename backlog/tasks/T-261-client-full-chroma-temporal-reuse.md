---
id: T-261
title: Client — full chroma without flicker: keep the last full colour in unchanged blocks when the aux frame is late, upgrade late pairs
status: review
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

- [x] Saf mantık JVM testli (blok karşılaştırma kuralı/toleransı CPU referans uygulamasıyla, geç yardımcı yükseltme kararı).
- [x] `./scripts/check.sh` geçer.
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

**Commit:** `b89c01d` (dal `task/T-261-chroma-reuse`; plan commit `6062c00`; handoff commiti bunun üstünde). `./scripts/check.sh` (tam çalıştırma) ALL OK.

**Dosyalar:** `client-android/app/src/main/kotlin/dev/matebridge/client/video/`: `ChromaReuse.kt` (yeni: blok kuralı + CPU referans durum modeli `ChromaReuseModel` + `LateUpgrade`), `PackedPresenter.kt` (tutulan ana görüntü, geç yükseltme, yeni zaman damgası biçimi, yeni sayaçlar), `FullChromaNative.kt`, `FullChromaPipeline.kt` (stats alanları, ana ImageReader `MAX_IMAGES + 1`), `AuxPairing.kt` (`find`); `cpp/mbfullchroma.cpp`; `docs/LOGGING.md`; test `video/ChromaReuseTest.kt` (16 test).

**Tasarım:** iki RGBA8 durum dokusu (ping-pong, tam çözünürlük, tampon koordinatları): RGB = ham Y/Cb/Cr (gösterilen), A = referans Y. Çizim iki geçiş: (1) durum geçişi (YUV_target ile ana + yardımcı -> `state[next]`): eşleşmiş karede bugünkü birleştirme (ham değerler); yalnız-ana karede 2x2 blok karşılaştırması (4 Y vs A, ana Cb/Cr vs durumun (çift,çift) Cb/Cr'si, tolerans 2): değişmediyse durumun tam kromu + güncel Y (A korunur -> kayma yok), değiştiyse ana kromu bloğa çoğalt (bugünkü yalnız-ana görüntüsü) ve A = güncel Y. (2) gösterim geçişi `state[next]` -> RGB -> pencere (eglPresentationTimeANDROID, fence, zaman damgaları aynen; T-256 düzeni korunur). Kurulum (shader/FBO) başarısızsa `chroma_reuse_unavailable` loglanır ve eski tek geçişli yol çalışır. Tolerans `ChromaReuse.TOLERANCE = 2` (`presentSetReuseTolerance`, negatif = reuse kapalı; PackedPresenter ctor `reuseTolerance`).

**Geç yardımcı:** son çizilen ana görüntü tutulur; yeni ana beklemiyorsa ve yardımcısı sonradan geldiyse (aux ring'de `capture_time_us` eşleşmesi) aynı kare birleştirilerek yeniden çizilir (sunum zamanı 0 = sonraki vsync, etiket -1: görüntü istatistiğine yeni kare olarak girmez), kare başına en çok bir kez; `late_upgrades++`. `offerAux` GL iş parçacığını uyandırır (25 ms tick beklemez).

**Ölçüm:** `render ev=stats` sonuna `reuse_pct` (her 4. yalnız-ana çizimde 64x40 örnek ızgarası, fence tamamlanınca `glReadPixels`; bekletmez) ve `late_upgrades`. `gl_ms`: `EXT_disjoint_timer_query` kaldırıldı; yerine EGL `RENDERING_COMPLETE_TIME` - takas öncesi CLOCK_MONOTONIC (gönderimden GPU bitişine, sıra bekleme dahil; destek yoksa CPU süresi). `ev=gl_present_init` artık `render_ts=`, `reuse=`, `reuse_tol=` yazar (`gpu_timer=` kalktı). LOGGING.md güncel.

**Varsayımlar / sapmalar**
- Bellek: 2 x RGBA8 2800x1840 = ~41 MB (+küçük örnek hedefi), kartın 15-20 MB tahmininin üstünde; A kanalı referans Y'yi taşıdığı için ek doku yok.
- Ana krom referansı = durum dokusunun (çift,çift) pikselindeki Cb/Cr'si (host `pick` ve yalnız-ana büyütmenin çoğaltması bunu tutarlı kılar).
- Ana ImageReader `maxImages` 7 (6+1): presenter son çizilen görüntüyü tutuyor.
- Gösterim için bir ek tam çözünürlüklü geçiş var: `gl_ms` artışı beklenir; `render_ts` ile ölçülür.
- GLSL cihaz dışında derlenemedi/çalıştırılamadı (yalnız NDK ile C++ derlendi); CPU referansı (`ChromaReuseModel`) kuralın birebir modeli.

**Cihazda kontrol edilecekler (Wi-Fi, Günlük 60, Tam renk; `adb logcat -s 'MB/*'`)**
1. `render ev=gl_present_init ... reuse=1 render_ts=1` (`reuse=0` ise `chroma_reuse_unavailable err=` satırındaki shader/FBO hatası; resim eski yolla yine doğru olmalı).
2. Resim doğru yönde/renkte mi (ilk kare, eşleşmiş ve yalnız-ana kareler; ters/dikey çevrik ya da renk bozulması durum/gösterim geçişi hatasıdır). Kaydırma sırasında durağan Apple Music ikonu titremiyor mu (asıl kabul).
3. `render ev=stats`: `reuse_pct` (kaydırmada yüksek, hareketli içerikte düşük olması normal), `late_upgrades` (durağan ekranda > 0), `aux_paired_pct` (değişmemeli), `gl_ms_p50/p95` (artık 0,01 değil), `gl_outstanding_max`, `skip_pct`, `cap_cb_p50/p95_us`: gecikme önceki Tam renk oturumuna göre değişmemeli.
4. Hızlı hareket sonrası ekran ~1 kare içinde tam renge oturuyor mu; yalnız-ana karede eski bloktan sızan hayalet renk görünüyor mu? Görünürse tolerans 2 -> 1/0 (tek yer: `ChromaReuse.TOLERANCE`).
5. Keskin <-> Tam renk hızlı geçiş, uygulamayı arka plana alıp geri getirme (`full_chroma_failed`/`fence_stall` olmamalı; `img_errors` artmamalı).

**Codex --high düzeltmeleri (P2 x3, aynı dal):** (1) Geç yükseltme artık özgün karenin etiketiyle (`seq`) çizilir; `FirstShown` her etiketin yalnız ilk gösterimini bildirir (özgün ya da yükseltme, hangisi önce görünürse; ikinci kez asla). Yükseltme, özgün karenin sunumu EGL damgasıyla doğrulanınca ya da hedef/çizim zamanı + 20 ms (`LateUpgrade.GRACE_NS`) geçince yapılır (özgün BufferQueue'da yerinden edilmesin). (2) `DrawWatch`: gönderilen her çizimin yaşı görüntü kuyruğundan bağımsız izlenir; tutulan (static ekran) görüntünün fence'i sinyal vermezse 500 ms'de `fence_stall` (retire kuyruğu kontrolüyle birlikte). (3) `gl_ms` başlangıç damgası artık ilk geçişten ÖNCE alınır (`presentDraw` içinde çizim çağrısından önce), takas sonrası değil. Testler: `LateUpgrade` geçidi, `FirstShown`, `DrawWatch` (`ChromaReuseTest`). check.sh ALL OK. Cihazda ek kontrol: durağan ekranda `late_upgrades` hâlâ > 0, ekran gecikmesi istatistiğinde kare kaybolmuyor (`shown_*` sayısı kare sayısıyla uyumlu), `gl_ms` önceki sürümden büyük (iki geçişin tamamı dahil).

**TEST EDİLMEDİ (cihaz gerekir):** GLSL derleme/doğruluğu (durum geçişleri, örnek ızgarası, gösterim geçişi), FBO tamlığı, RENDERING_COMPLETE damgasının `gl_ms` için geçerliliği, örnek okumanın bekletmediği, bellek/gecikme etkisi, tolerans seçimi (T-253 netleştirme ile).

## Open questions
