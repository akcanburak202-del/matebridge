---
id: T-013
title: Android görüntü çözme — MediaCodec HEVC düşük gecikme, SurfaceView, sınırlı kuyruk
status: review
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

- [ ] `VideoRenderer`: `STREAM_CONFIG`'e göre MediaCodec (HEVC, gerekirse H.264) + `SurfaceView`. `KEY_LOW_LATENCY` destekleniyorsa açık (NOTES: XML'de ilan edilmemiş, çalışma zamanında denenir, sonuç loglanır). Renk bilgisi `STREAM_CONFIG`'ten.
- [ ] Kuyruk kuralları (PROTOCOL.md §5) saf Kotlin ve JVM testli: en çok 2 kare, taşmada eskiler atılır, keyframe gelene kadar P-kareler verilmez, `KEYFRAME_REQUEST` üretilir.
- [ ] Sayaçlar: alınan/çözülen/gösterilen/atılan kare, ortalama çözme süresi (STATS için).
- [ ] Debug kaynak kümesinde test ekranı: `/sdcard/Android/data/dev.matebridge.client/files/test.h265` dosyasını (T-011 dökümü) gerçek hızda oynatır ve sayaçları gösterir. Orkestratör cihazda doğrular.
- [ ] Yüzey yok olunca/arka plana geçince codec temizce durur, geri gelince keyframe istenir.
- [ ] `./scripts/check.sh` geçiyor.

## Plan

`FrameQueue` (saf, testli) kuralları uygular; `VideoStats` sayaçlar; `ColorMapping` H.273 -> MediaFormat; `VideoRenderer` tek decoder thread'i ile MediaCodec + Surface (yalnızca en yeni çıktı render edilir); `AnnexBSplitter` T-011 dökümünü kareye böler; debug `VideoTestActivity` dosyayı döngüde gerçek hızda oynatır.

## Handoff

- **Commit:** bkz. `git log task/T-013-video-decode` (T-013 commit'i)
- **Dokunulan dosyalar:** app/src/main/kotlin/dev/matebridge/client/video/{FrameQueue,VideoStats,ColorMapping,AnnexBSplitter,VideoRenderer}.kt; app/src/debug/AndroidManifest.xml; app/src/debug/kotlin/dev/matebridge/client/debug/VideoTestActivity.kt; app/src/test/.../video/VideoTest.kt
- **Varsayımlar:** Bekleyen sınırı 2, keyframe dahil (CODEC_CONFIG hariç). Taşmada bekleyen tüm P-kareler ve gelen kare atılır, FRAMES_DROPPED istenir. Keyframe gelince eski bekleyenler atılır. Son CODEC_CONFIG saklanır, surface dönünce yeniden verilir (reset -> STARTUP isteği). pts = frameSeq. KEYFRAME_REQUEST `onKeyframeRequest` callback'i ile çıkar (T-015 bağlar). Test dosyası yalnızca HEVC; H.264 yolu kodda var, denenmedi. sRGB transfer (13) SDR_VIDEO'ya eşlenir. Debug ekran konfigürasyonu BT.709 sınırlı aralık varsayar.
- **Test edilmeyenler / cihazda doğrulanacaklar:** MediaCodec hiç çalıştırılmadı. `adb push test.h265 /sdcard/Android/data/dev.matebridge.client/files/test.h265`, sonra `adb shell am start -n dev.matebridge.client/.debug.VideoTestActivity` (opsiyonel `--ei fps 60`, dökümün fps'iyle eşleşmeli). Bak: tam ekran akıcı görüntü, shown/s ~ fps, drop ~0, decode avg; `adb logcat -s MB/decoder` içinde `ev=codec_start ... low_latency=on|unsupported`. Home'a çık/dön: codec durur, dönünce oynatma yeniden başlar (kf requests artar). Renk doğru mu.
- **Açık sorular:** Yok.
