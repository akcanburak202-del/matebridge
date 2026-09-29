---
id: T-018
title: Tablette sunum kontrolü — GL yolu (SurfaceTexture), vsync'e hizalı çizim, 120 Hz denemesi
status: review
phase: 1
owner: android-client-dev
depends_on: [T-016, T-017]
decisions: [0004]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/
  - client-android/app/src/main/kotlin/dev/matebridge/client/stream/
  - client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt
  - client-android/app/src/main/res/layout/
  - client-android/app/src/test/kotlin/dev/matebridge/client/video/
---

## Amaç

Mac tarafı artık kusursuz 60 fps veriyor (T-017). USB'de bile tablette "hâlâ takılma var". MediaCodec → SurfaceView yolunda gösterim zamanını kontrol edemiyoruz: HarmonyOS video yüzeyini 60 Hz'e kilitliyor, zamanlı `releaseOutputBuffer` etkisiz görünüyor (T-016). Hedef: kareyi ne zaman göstereceğimizi kendimiz belirlemek.

## Kabul kriterleri

- [ ] **Deney anahtarı:** `--es render surface|gl` (varsayılan: sonuca göre orkestratör seçer). Mevcut SurfaceView yolu bozulmadan kalır.
- [ ] **GL yolu:** MediaCodec → `SurfaceTexture` (OES doku) → `GLSurfaceView`/kendi EGL iş parçacığı. `Choreographer` vsync'inde en yeni hazır kare çizilir; gerekiyorsa `eglPresentationTimeANDROID` ile bir sonraki vsync'e hizalanır. Renk dönüşümü decoder'dan (tam aralık, BT.709) doğru gelir; ölçek 1:1 (2800×1840, filtre yok, bulanıklık yok).
- [ ] **120 Hz:** GL yüzeyinde `Surface.setFrameRate(…, FIXED_SOURCE)` ve `preferredDisplayModeId` ile 120 Hz istenir; gerçekten uygulanan vsync loglanır. SurfaceView yolunda da `setFrameRate(120, FIXED_SOURCE)` denenir.
- [ ] **Gerçek gösterim ölçümü:** GL yolunda `eglSwapBuffers` sonrası gösterim zamanı (mümkünse `EGL_ANDROID_get_frame_timestamps`) ile `shown_` aralıkları; >1,5×vsync sayısı. SurfaceView yolunun `shown_` değeriyle karşılaştırılabilir log.
- [ ] Gecikme: GL yolu SurfaceView'e göre en fazla ~1 vsync ekler; ölçülüp loglanır.
- [ ] Yaşam döngüsü: arka plan/ön plan, config değişimi, yüzey yok olması GL bağlamını sızdırmadan yönetilir.
- [ ] `./scripts/check.sh` geçiyor.

## Notlar

- Orkestratör karşılaştırması: Mac'te Safari 60 fps sayfası, Wi-Fi ve USB, `render=surface` vs `render=gl`, kullanıcı gözüyle.
- HarmonyOS video katmanı sınırlaması bir üretici politikası olabilir; GL yolu "video" olarak etiketlenmediği için 120 Hz alabilir, ama garanti değil.

## Plan

1. `render` extra: `surface` (mevcut yol, değişmedi) | `gl`. Yerleşimde ikinci gizli `SurfaceView` (`video_gl`).
2. `GlPresenter`: kendi "mb-gl" iş parçacığı + EGL14; MediaCodec -> `SurfaceTexture` (OES); aynı iş parçacığında `Choreographer`: her vsync'te yeni kare varsa `updateTexImage` (en yeni kare) + 1:1 NEAREST çizim + `eglSwapBuffers`. `active` bayrağı vsync döngüsünü yalnız akışta çalıştırır.
3. `PresentStats` (saf Kotlin, JVM testli): vsync/kaçan vsync, çizilen, birleşen kare, bekleme (hazır -> çizim = eklenen gecikme), swap süresi.
4. `Surface.setFrameRate(FIXED_SOURCE)`: GL'de varsayılan `hz` (120); `--ei frate N` iki yolda da geçerli.
5. Yaşam döngüsü: yüzey oluşunca presenter başlar, decoder yüzeyi hazır olunca `attachSurface`; yüzey yok olunca önce decoder ayrılır, sonra presenter GL'yi ve yüzeyi bırakır.

## Handoff

- **Commit:** `git log task/T-018-gl-presentation -1` (`T-018: GL presentation path ...`)
- **Dokunulan dosyalar:** `video/GlPresenter.kt` (yeni), `video/PresentStats.kt` (yeni), `video/VideoRenderer.kt` (yalnız `codecReportsShown` parametresi), `MainActivity.kt`, `res/layout/activity_main.xml`, `test/.../video/PresentStatsTest.kt`.
- **Varsayımlar:** GL yüzeyi (`video_gl`) akış en-boy oranına göre boyutlanıyor (surface yoluyla aynı) => 2800x1840'ta 1:1. Renk dönüşümünü sürücü SurfaceTexture tamponunun dataspace'inden yapıyor (shader ham OES örnekliyor). "shown" = karenin çizildiği vsync'in Choreographer zamanı (`EGL_ANDROID_get_frame_timestamps` Java'da yok, gerçek ekran zamanı alınamıyor); aralıklar vsync periyodunun katı çıkar. GL yolunda jitter arabelleği devre dışı.
- **Kullanım:** `adb shell am start -n dev.matebridge.client/.MainActivity --es render gl` (isteğe bağlı `--ei hz 120`, `--ei frate 120|0`, `--ez glpts true`). Karşılaştırma: `--es render surface` (varsayılan; `--ei frate 120` SurfaceView'de FIXED_SOURCE denemesi). Loglar (tag `MB`, component `render`): `render_mode`, `set_frame_rate`, `gl_ready`, `gl_stats` (gl_vsync, gl_missed, gl_drawn, gl_coalesced, gl_wait_avg/max_ms = eklenen gecikme, gl_swap_*, gl_vsync_period_us) ve mevcut `stats` satırındaki `shown_*` (>1,5xvsync sayısı dahil).
- **Test edilmeyenler / cihazda doğrulanacaklar:** hiçbiri cihazda çalıştırılmadı (yalnız derleme + JVM). (1) GL yolu görüntü veriyor mu; renk (siyah seviyesi) ve 1:1 keskinlik; (2) `gl_vsync_period_us` 8333 mü (120 Hz) yoksa 16667 mi; (3) `gl_wait_avg_ms` <= ~1 vsync; (4) `shown_` >1,5xvsync sayısını surface yoluyla karşılaştır; (5) arka plana gidip dönme / yüzey yeniden oluşması, `gl_stop_slow` logu yok; (6) `--ez glpts true` etkisi; (7) `--ei frate 120` iki yolda.
- **Açık sorular:** SurfaceTexture tüketicisi kare işlemezken decoder çıkışını bloklarsa `ready` aralıkları bozulur; cihazda gözlenmeli. Vsync döngüsü 120 Hz alınırsa 60 fps içerikte de 120 uyanma/sn yapar; gerekirse sonra seyreltilir.
