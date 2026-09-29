---
id: T-013
title: Android görüntü çözme — MediaCodec HEVC düşük gecikme, SurfaceView, sınırlı kuyruk
status: done
phase: 1
owner: android-client-dev
depends_on: [T-009]
decisions: [0004]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/
  - client-android/app/src/debug/
  - client-android/app/src/test/kotlin/dev/matebridge/client/video/
---

## Amaç

`VIDEO_FRAME` akışını tam ekran ve düşük gecikmeyle göstermek. Ağdan bağımsız: girdi bir kare kaynağı arayüzüdür; T-015 oturumla bağlar.

## Kabul kriterleri

- [x] `VideoRenderer`: `STREAM_CONFIG`'e göre MediaCodec (HEVC, gerekirse H.264) + `SurfaceView`. `KEY_LOW_LATENCY` destekleniyorsa açık (NOTES: XML'de ilan edilmemiş, çalışma zamanında denenir, sonuç loglanır). Renk bilgisi `STREAM_CONFIG`'ten.
- [x] Kuyruk kuralları (PROTOCOL.md §5) saf Kotlin ve JVM testli: en çok 2 kare, taşmada eskiler atılır, keyframe gelene kadar P-kareler verilmez, `KEYFRAME_REQUEST` üretilir.
- [x] Sayaçlar: alınan/çözülen/gösterilen/atılan kare, ortalama çözme süresi (STATS için).
- [x] Debug kaynak kümesinde test ekranı: `/sdcard/Android/data/dev.matebridge.client/files/test.h265` dosyasını (T-011 dökümü) gerçek hızda oynatır ve sayaçları gösterir. Orkestratör cihazda doğrular.
- [x] Yüzey yok olunca/arka plana geçince codec temizce durur, geri gelince keyframe istenir.
- [x] `./scripts/check.sh` geçiyor.

## Plan

`FrameQueue` (saf, testli) kuralları uygular; `VideoStats` sayaçlar; `ColorMapping` H.273 -> MediaFormat; `VideoRenderer` tek decoder thread'i ile MediaCodec + Surface (yalnızca en yeni çıktı render edilir); `AnnexBSplitter` T-011 dökümünü kareye böler; debug `VideoTestActivity` dosyayı döngüde gerçek hızda oynatır.

## Handoff

- **Commit:** bkz. `git log task/T-013-video-decode` (T-013 commit'i)
- **Dokunulan dosyalar:** app/src/main/kotlin/dev/matebridge/client/video/{FrameQueue,VideoStats,ColorMapping,AnnexBSplitter,VideoRenderer}.kt; app/src/debug/AndroidManifest.xml; app/src/debug/kotlin/dev/matebridge/client/debug/VideoTestActivity.kt; app/src/test/.../video/VideoTest.kt
- **Varsayımlar:** Bekleyen sınırı 2, keyframe dahil (CODEC_CONFIG hariç). Taşmada bekleyen tüm P-kareler ve gelen kare atılır, FRAMES_DROPPED istenir. Keyframe gelince eski bekleyenler atılır. Son CODEC_CONFIG saklanır, surface dönünce yeniden verilir (reset -> STARTUP isteği). pts = frameSeq. KEYFRAME_REQUEST `onKeyframeRequest` callback'i ile çıkar (T-015 bağlar). Test dosyası yalnızca HEVC; H.264 yolu kodda var, denenmedi. sRGB transfer (13) SDR_VIDEO'ya eşlenir. Debug ekran varsayılanı tam aralık (full_range=1), transfer 13.
- **Test edilmeyenler / cihazda doğrulanacaklar:** MediaCodec hiç çalıştırılmadı. `adb push test.h265 /sdcard/Android/data/dev.matebridge.client/files/test.h265`, sonra `adb shell am start -n dev.matebridge.client/.debug.VideoTestActivity` (opsiyonel `--ei fps 60`, dökümün fps'iyle eşleşmeli). Bak: tam ekran akıcı görüntü, shown/s ~ fps, drop ~0, decode avg; `adb logcat -s MB/decoder` içinde `ev=codec_start ... low_latency=on|unsupported`. Home'a çık/dön: codec durur, dönünce oynatma yeniden başlar (kf requests artar). Renk doğru mu.
- **Review düzeltmeleri:** Decoder hatasında aynı surface'te codec yeniden başlar (kuyruk reset, son CODEC_CONFIG tekrar, KEYFRAME_REQUEST(DECODE_ERROR)); `RestartPolicy` 10 sn'de en çok 3, sonra `onGiveUp` callback'i. Attach/detach ekleme başına token'lı, detach join'i 300 ms, eski thread çıkmadan yeni thread codec açmaz. KEY_MAX_INPUT_SIZE = w*h*3/2, taşan kare atılır ve keyframe istenir. Debug: `--ei full_range 0|1` (varsayılan 1), `--ei primaries 1|12`. Çıktı formatındaki renk anahtarları bir kez loglanır (`ev=output_format`). Atlanan çıktılar dropped sayılır.
- **T-015 için notlar:** (1) Keyframe beklerken (kapı kapalıyken) `KEYFRAME_REQUEST` tek seferliktir; T-015 kapı açılana kadar her 500 ms'de yeniden istemelidir (`FrameQueue.isWaitingKeyframe()`). (2) Renderer detach iken T-015 kareleri kuyruğa vermeyi bırakmalıdır (onFrame çağırmamalı); attach'te kuyruk zaten reset edilir ve STARTUP istenir.
- **Açık sorular:** (1) `primaries=12` (Display P3) Android MediaFormat'ında karşılığı yok; yalnızca uyarı loglanır, hangi primaries'in uygulandığı cihazda `ev=output_format` ile görülmeli. (2) sRGB transfer (13) SDR_VIDEO'ya eşleniyor, gerçek gösterimi cihazda doğrulanmalı. (3) Codec yeniden başlatma ve detach_slow yolları cihazda hiç denenmedi. (4) `--ei` fps dökümün gerçek fps'iyle elle eşleştirilmeli.

## Orkestratör cihaz testi (2026-09-29)

T-011'in `--dump-video` çıktısı (6 sn, 138 kare) `VideoTestActivity` ile 30 fps oynatıldı: `OMX.hisi.video.decoder.hevc` 2800×1840, 30/30/30, 0 atma, 29,8 fps, çözme ort. ~16 ms. Çıkış formatı range=1 (tam) standard=1 (BT.709). `KEY_LOW_LATENCY` desteklenmiyor. Ana ekrana gidip dönünce codec temiz durdu ve oynatma yeniden başladı. Çökme yok. Hata sonrası yeniden başlatma yolu cihazda tetiklenmedi.

