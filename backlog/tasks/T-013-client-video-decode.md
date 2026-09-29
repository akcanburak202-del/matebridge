---
id: T-013
title: Android görüntü çözme — MediaCodec HEVC düşük gecikme, SurfaceView, sınırlı kuyruk
status: todo
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

_(Ajan doldurur.)_

## Handoff

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
