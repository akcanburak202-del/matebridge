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

- **Oturum onayı (Codex T-257):** istemci `HELLO.capabilities` bit11 `FULL_CHROMA`'yı yalnız yetenek testi geçtiyse yazar.

## Kabul kriterleri

- [ ] Fixture testleri + birim testleri (eşleme, yalnız-ana geri düşüş, yardımcı kuyruğu, KEYFRAME_REQUEST view, tercih kuralları, yetenek saklama); `./scripts/check.sh` geçer.
- [ ] `chroma_layout = 0` yolunda davranış değişikliği yok (mevcut testler aynen).
- [ ] Handoff: cihaz kabul adımları — 0034 §9 durdurma kuralı ölçümü (aynı oturumda Keskin ↔ Tam renk: ekran gecikmesi p50/p95 farkı, `skip_pct`), `aux_paired_pct`, Wi-Fi ve USB.

## Plan

Dilimler (her biri JVM testli saf mantık + ince Android yapıştırıcı):

1. **Codec** (yapıldı): `StreamConfig.chromaLayout`, `VideoFrame.view`, `KeyframeRequest.view` (isteğe bağlı), `StreamPrefs.CHROMA_FULL`, `Capabilities.FULL_CHROMA`; 5 yeni fixture `FixtureTest`'te.
2. **Tercih/yetenek** (`stream/ColourChoice.kt`, `video/FullChromaCapability.kt`): `ColourChoice` (Normal/Keskin/Tam renk) okuma (`colour` anahtarı, yoksa eski `sharp_chroma`); `FullChromaPolicy.chromaRequest` (Günlük + 60 fps + doğal ekran + SDR + yetenek → 2, aksi halde Tam renk seçiliyse 1); `FullChromaCapability` kalıcı sonuç (APK sürüm anahtarlı; panel T-260 okur); `HELLO` bit11 yalnız geçtiyse (`SessionController` hello'ya çağrı anında OR'lanan sağlayıcı).
3. **Düzen matematiği** (`video/Avc444v2.kt`): ters eşleme (`sourceOf`), `YuvConversion` katsayıları; testte Swift `AVC444v2.pack`'in Kotlin kopyasıyla gidiş-dönüş bit-tamlığı. GLSL bu fonksiyonun satır satır çevirisidir.
4. **Yardımcı hat saf mantığı**: `AuxFrameQueue` (sınırlı, en yeni kazanır, CODEC_CONFIG saklanır, keyframe kapısı, `KEYFRAME_REQUEST(view=1)` hold-off), `AuxPairing` (son N yardımcı kare, `capture_time_us` ile eşleme, yalnız-ana geri düşüşü, `aux_paired_pct`/`aux_late`), `PackedStats` (gl_ms p50/p95).
5. **Native** (`cpp/mbfullchroma.cpp`, T-254/T-256 kodundan): EGL pencere yüzeyi (swap interval 0), AHardwareBuffer → EGLImage → `GL_EXT_YUV_target` dokuları, birleştirme/yalnız-ana programları, `eglPresentationTimeANDROID`, EGL zaman damgaları (present zamanı), GPU zamanlayıcı; pbuffer üstünde ham örnekleme karşılaştırması (yetenek testi).
6. **Sunucu** (`video/PackedPresenter.kt`, `AuxDecoder.kt`, `FullChromaPipeline.kt`): GL iş parçacığı (ana görüntü posta kutusu newest-wins, yardımcı halka, görüntüler bir çizim geç kapanır), ikinci `MediaCodec` + ImageReader, ana akış `VideoRenderer`'a küçük kanca: çıkış yüzeyi ana ImageReader'ın yüzeyi, `release` -> `releaseOutputBuffer(idx, true)` + `presenter.expect(pts, captureUs, renderNs)`; GL yolu ek öncü süre (`extraLeadNs`); gösterim zamanı EGL present zamanından `stats.onRenderCallback`'e. `chroma_layout = 0` yolu kancalar `null` iken değişmez.
7. **Bağlama** (`MainActivity`, `SessionController`): yapılandırma `isPacked444` ise boru hattı yeniden kurulur, aksi halde bugünkü yol; `view = 1` kareler boru hattına, tek akışta atılır; yardımcı hatası ayrı sayaç, yardımcı yeniden kurulur; GL başlatma hatasında yalnız-ana doğrudan yola düşülür (log).
8. **Yetenek testi** (`FullChromaSelfTest`): ilk kullanımda ve APK güncellenince arka planda: GL_EXT_YUV_target + ham örnekleme CPU ile bit-tam (gömülü küçük HEVC IDR, T-254 `t2` mantığı) + ikinci MediaCodec açılabiliyor mu; sonuç saklanır, başarısızsa `chroma = 2` ve bit11 hiç gönderilmez.
9. **Ölçüm**: `render ev=stats`'a `chroma_layout`, `aux_paired_pct`, `aux_late`, `gl_ms_p50/p95`; docs/LOGGING.md.

Kısıt: tablet/adb yok; GL ve MediaCodec yapıştırıcısı yalnız derleme + JVM testiyle doğrulanır, cihaz adımları Handoff'ta.

## Handoff

## Open questions
