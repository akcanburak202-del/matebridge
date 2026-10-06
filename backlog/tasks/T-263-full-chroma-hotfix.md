---
id: T-263
title: Client — Tam renk acil düzeltme: ana ImageReader 6 imaj, ana dekoder çökünce negotiated geri dönüş, "Görüntü durdu" düğmesi okunur
status: done
phase: 6
owner: android-client-dev
depends_on: [T-261]
decisions: [0034]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/
  - client-android/app/src/main/res/
  - client-android/app/src/test/kotlin/dev/matebridge/client/
  - backlog/tasks/T-263-full-chroma-hotfix.md
---

## Amaç

Cihaz günlüğü (2026-10-06 01:29, Tam renk seçildi, video hiç gelmedi, ekran "Görüntü durdu"da takıldı): ana ImageReader T-261'de `MAX_IMAGES + 1 = 7` yapıldı; `OMX.hisi.video.decoder.hevc` ACodec `nBufferCountActual` ayarını 6'ya düşürüp `setMaxDequeuedBufferCount (-2)` ile `native_window_set_buffer_count failed` veriyor -> kodek başlamıyor -> 4x `decode_error` -> `decoder_give_up` -> video_health FAULT. 6 ile (T-261 öncesi) çalışıyordu. Üç hata:

1. Ana ImageReader 6'ya dön; tutulan (geç yükseltme) görüntü bütçeyi tüketmesin.
2. Packed modda ana dekoder çökerse istemci vazgeçmemeli: `onFullChromaFailed` (süreç mandalı -> `chroma=1` -> doğrudan yol) ile resim geri gelmeli.
3. "Görüntü durdu" kutusundaki "Yeniden dene" düğmesi boş beyaz görünüyordu (etiket yok).

## Plan

1. `FullChromaPipeline`: ana reader `MAX_IMAGES` (6). `PackedPresenter`: yalnız yükseltilebilir (eşleşmemiş, beklentili) karenin görüntüsü tutulur; eşleşmiş/hatalı çizimde hemen retire kuyruğuna. Tutulan görüntü yükseltilince ya da `LateUpgrade.HOLD_NS` (250 ms, GRACE sonrası) dolunca bırakılır (`LateUpgrade.holdsImage`, saf, JVM testli). Bütçe: tutulan <= 1 + bekleyen slot 1 + fence bekleyen retire <= 3 < 6, dekoder için >= 1 kalır.
2. `MainActivity`: `VideoRenderer.onGiveUp` -> UI iş parçacığında `onMainDecoderGaveUp()`: `packedVideo` ve boru hattı aktifse `onFullChromaFailed("main_decoder_give_up")` (mevcut mekanizma: `FullChromaRuntime.disable`, doğrudan yola geçiş, `STREAM_PREFS`).
3. "Yeniden dene" düğmesi: tema varsayılanı beyaz zemin üstüne beyaz yazı veriyordu; açık gri zemin + siyah yazı kodda açıkça verildi.

## Handoff

**Commit:** `10e667f` (dal `task/T-263-full-chroma-hotfix`; ajan oturum sonunda durduruldu, orkestratör inceleyip tamamladı). `./scripts/check.sh` ALL OK.

**Dosyalar:** `video/FullChromaPipeline.kt` (ana reader `MAX_IMAGES` = 6), `video/PackedPresenter.kt` (`held` yalnız yükseltilebilir kare için; `releaseHeld()`), `video/ChromaReuse.kt` (`LateUpgrade.HOLD_NS`, `holdsImage`), `MainActivity.kt` (`onMainDecoderGaveUp` -> `onFullChromaFailed`; "Yeniden dene" düğme renkleri), test `ChromaReuseTest.kt` (+3 test).

**Varsayımlar**
- Ana reader bütçesi: tutulan <= 1 + bekleyen slot 1 + fence bekleyen retire (uçuştaki çizimler, ~3) < 6. Fence gecikirse dekoder bekler (geri basınç), kilitlenmez; fence hiç gelmezse mevcut `fence_stall` bekçisi devrede.
- Geri dönüş sırası: `onGiveUp` UI'ye geri dönüşü, ardından eski neslin `Fault`'unu postalar; doğrudan yol bağlanınca yeni `Generation` gelir ve eski `Fault` yok sayılır. `attachDirect` ertelenirse (yüzey meşgul) "Görüntü durdu" kısa süre görünebilir, ertelenen bağlanmada düzelir.
- `onFullChromaFailed` süreç mandalıdır: bu süreçte Tam renk bir daha istenmez (uygulama yeniden başlayınca tekrar denenir).

**TEST EDİLMEDİ (cihaz gerekir):** Hisi dekoderin 6 imajla packed modda açılması (T-261 öncesi çalışıyordu), geç yükseltmenin 6 bütçeyle hâlâ çalışması (`late_upgrades` > 0), ana dekoder çökünce otomatik Keskin/doğrudan yola dönüş, düğme etiketinin görünmesi.

## Open questions

- Yok.
