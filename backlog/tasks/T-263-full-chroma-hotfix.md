---
id: T-263
title: Client — Tam renk acil düzeltme: ana ImageReader 6 imaj, ana dekoder çökünce negotiated geri dönüş, "Görüntü durdu" düğmesi okunur
status: review
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

Aşağıda (commit sonrası).

## Open questions

- Yok.
