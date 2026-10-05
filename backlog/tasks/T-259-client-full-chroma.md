---
id: T-259
title: Client — packed full chroma (decision 0034): codecs, capability test, second decoder, ImageReader + GL merge path, pairing, prefs
status: ready
phase: 6
owner: android-client-dev
depends_on: [T-257, T-252]
decisions: [0034, 0033, 0021]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/protocol/
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/
  - client-android/app/src/main/kotlin/dev/matebridge/client/stream/
  - client-android/app/src/main/kotlin/dev/matebridge/client/session/
  - client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt
  - client-android/app/src/main/cpp/
  - client-android/app/src/test/kotlin/dev/matebridge/client/
  - client-android/app/build.gradle.kts
  - docs/LOGGING.md
  - backlog/tasks/T-259-client-full-chroma.md
---

## Amaç

Karar 0034'ün istemci tarafı (panel hariç: T-260). Protokol `task/T-257-full-chroma-protocol` dalında; **bu dalın üzerine kur** (`git checkout -b task/T-259-client-full-chroma task/T-257-full-chroma-protocol`). Protokolü değiştirme.

## Bağlam

- **Codec (Kotlin):** `chroma_layout`, `view`, isteğe bağlı `KEYFRAME_REQUEST.view` (yalnız `chroma_layout = 1` iken yazılır), `chroma = 2`. Bütün fixture testleri.
- **Yetenek testi:** ilk kullanımda (ve APK güncellenince) kısa bir kendi kendine test: `GL_EXT_YUV_target` var mı, bilinen desenli küçük bir kareyi çözüp GPU'dan bit-tam okuyabiliyor mu (T-254 `t2` mantığı), ikinci `MediaCodec` açılabiliyor mu. Sonuç kalıcı saklanır; `FullChromaCapability` (panel T-260 bunu okur). Başarısızsa `chroma = 2` hiç gönderilmez.
- **Tercih:** kayıtlı "Renk" değeri (Normal/Keskin/Tam renk; T-260 taşıma yapar, burada okuma). `chroma = 2` yalnız Günlük + 60 fps + doğal ekran + SDR + yetenek varken; aksi halde `1` (Tam renk seçiliyse) ya da kayıtlı değer.
- **Video yolu:** `chroma_layout = 0` iken bugünkü doğrudan SurfaceView yolu **hiç değişmez**. `chroma_layout = 1` iken:
  - iki `MediaCodec` (ana + yardımcı), her biri `ImageReader` (PRIVATE, GPU örneklenebilir) çıkışlı; yardımcının ayrı sınırlı kuyruğu, `frame_seq` akış başına PTS.
  - Eşleme `capture_time_us` ile; GL iş parçacığı (T-254/T-256 native kodu ürün `cpp/` altına taşınır; `EXT_YUV_target`) ana + eşleşen yardımcıyı AVC444v2 ters eşlemesiyle birleştirir (T-255 düzeni; `pick`), RGB'ye çevirip aynı SurfaceView'ın EGL yüzeyine yazar. Yardımcı zamanında yoksa yalnız-ana (shader rengi büyütür).
  - **Sunum:** T-256 sonucu — duran kuyruk YOK: swap interval 0 + `eglPresentationTimeANDROID` slot hedefi ya da derinlik-1; `AdaptivePacer`/`SlotReleaser` slot mantığı korunur (hazır = ana hazır + GL geçişi). Yerleşim, ölçek ve girdi eşlemesi değişmez.
  - T-252 yetişme ana akışta aynen; yardımcıda newest-wins + `KEYFRAME_REQUEST(view=1)` (PROTOCOL §5).
  - Akış başına çözücü sağlığı; yardımcı hatası `video_health`'i düşürmez (ayrı sayaç), yardımcı yeniden kurulur.
- **Ölçüm (kabul şartı için):** `render ev=stats`'a `chroma_layout`, `aux_paired_pct`, `aux_late`, `gl_ms_p50/p95`; ekran gecikmesi bugünkü alanlarla (`latency_us`, `shown_*`) aynı tanımla iki yolda karşılaştırılabilir olmalı. `--ez dev true --ez full_chroma_direct true` gibi bir A/B düğmesi gerekmez: panelden Keskin ↔ Tam renk geçişi A/B'dir; ama aynı oturumda hızlı geçiş mümkün olmalı.
- Yeni bağımlılık ekleme (NDK/CMake zaten var, AAudio native modülü). Mac'te pencere açma; adb/tablet yok.

## Kabul kriterleri

- [ ] Fixture testleri + birim testleri (eşleme, yalnız-ana geri düşüş, yardımcı kuyruğu, KEYFRAME_REQUEST view, tercih kuralları, yetenek saklama); `./scripts/check.sh` geçer.
- [ ] `chroma_layout = 0` yolunda davranış değişikliği yok (mevcut testler aynen).
- [ ] Handoff: cihaz kabul adımları — 0034 §9 durdurma kuralı ölçümü (aynı oturumda Keskin ↔ Tam renk: ekran gecikmesi p50/p95 farkı, `skip_pct`), `aux_paired_pct`, Wi-Fi ve USB.

## Plan

## Handoff

## Open questions
