---
id: T-018
title: Tablette sunum kontrolü — GL yolu (SurfaceTexture), vsync'e hizalı çizim, 120 Hz denemesi
status: todo
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

_(Ajan doldurur.)_

## Handoff

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
