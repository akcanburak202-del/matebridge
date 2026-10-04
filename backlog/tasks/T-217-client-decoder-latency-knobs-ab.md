---
id: T-217
title: A/B HiSilicon decoder low-latency keys and operating rate (dev knob)
status: in-progress
phase: 6
owner: android-client-dev
depends_on: [T-185, T-219]
decisions: [0026]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/VideoRenderer.kt   # createCodec only
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/OperatingRate.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/DecoderCodec.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/session/DevKnobs.kt
  - client-android/app/src/test/kotlin/dev/matebridge/client/video/
  - client-android/app/src/test/kotlin/dev/matebridge/client/session/DevKnobsTest.kt
  - docs/KNOBS.md
  - docs/LOGGING.md
  - backlog/tasks/T-217-client-decoder-latency-knobs-ab.md
---

## Amaç

Araştırma (docs/research/2026-10-04-smoothness.md §1, §4): oyun modunda 2800×1840@60 çözme p50 ~18 ms, aynı boyutta 120 fps çizimde ~9,3 ms → büyük olasılıkla decoder 60 fps'te düşük saatte çalışıyor (DVFS). Moonlight HiSilicon için `vendor.hisi-ext-low-latency-video-dec.video-scene-for-low-latency-req=1` ve `…-rdy=-1`, ayrıca `vdec-lowlatency=1`, `low-latency=1` kullanıyor; MateBridge hiçbirini ayarlamıyor ve `KEY_OPERATING_RATE` = akış fps'i. Bu kart, varsayılanı değiştirmeden bunları A/B için bir geliştirici ayarının arkasına koyar.

## Bağlam

- `--ez dev true --es dec_lowlat hisi|vdec|all|off` (varsayılan `off`) ve `--ez dev true --ei dec_oprate max|fps` (ya da benzer; 0026: varsayılan kapalı, kapatan kart adı). `createCodec` anahtarları ekler; `configure` başarısız olursa **anahtarsız bir kez yeniden dener** ve `W decoder ev=dec_lowlat_rejected` loglar.
- API 31: `MediaCodec.getSupportedVendorParameters()` sonucu codec başına bir kez loglanır (yalnız anahtar adları).
- `ev=codec_start` alanlarına `lowlat=` ve `oprate=` eklenir.
- T-219 `VideoRenderer.kt`'yi değiştirir; bu kart onun ardından gelir ve yalnız `createCodec` bölgesine dokunur.

## Kabul kriterleri

- [ ] [JVM] Ayar yokken `createCodec`'in koyduğu anahtarlar ve değerler bugünküyle aynı (format anahtar listesi testi).
- [ ] [JVM] `dec_lowlat=all` ile dört anahtar formatta; configure hatasında anahtarsız tek yeniden deneme (fake codec).
- [ ] [JVM] `dev` olmadan yok sayılır (`ignored=dec_lowlat`).
- [ ] [device] Oyun 60 tam boyut ve Akıcı çizim, ayar açık/kapalı dönüşümlü: `dec_p50/p95_us`, `latency_us`, SoC sıcaklığı 5 dk; sonuç NOTES'a, varsayılan için öneri.

## Plan

1. Kilit testi önce (mevcut koda karşı): ayar yokken `createCodec`'in formata koyduğu anahtar/değer listesi (sıra dahil) `FakeDecoderFactory` ile sabitlenir.
2. `OperatingRate.kt`: saf `DecoderLatencyKnobs` (`lowLat` off|hisi|vdec|all, `opRate` fps|max). `hisi` = iki `vendor.hisi-ext-low-latency-video-dec.*` anahtarı (`…-req=1`, `…-rdy=-1`); `vdec` = `vdec-lowlatency=1`, `low-latency=1`; `all` = dördü. `max` = `KEY_OPERATING_RATE = Short.MAX_VALUE` (Moonlight). Varsayılan = bugünkü davranış.
3. `DevKnobs.kt`: `--es dec_lowlat off|hisi|vdec|all`, `--es dec_oprate fps|max` (kartta `--ei` yazıyor ama değer metin; `--es` kullanılır), yalnızca geliştirici, `ev=profile knobs=` içinde. Alan: `decoderLatency`.
4. `DecoderCodec.kt`: `supportedVendorParameters` (API 31+, aksi hâlde null).
5. `VideoRenderer.kt`: yapıcıya `decoderTuning` (varsayılan DEFAULT) + `createCodec`: varsayılanda anahtarlar ve hata yolu aynı; ayar açıkken configure/start hata verirse codec bırakılır, yeni codec ile **anahtarsız bir kez** denenir, `W decoder ev=dec_lowlat_rejected` (yalnız anahtar adları). `ev=codec_start`'a `lowlat=` `oprate=` (`accepted`'tan önce). `I decoder ev=vendor_params` codec adı başına bir kez (yalnız anahtar adları).
6. JVM testleri (fake codec), `docs/KNOBS.md`, `docs/LOGGING.md`.
7. Kapsam dışı: `MainActivity.kt` bağlantısı (`DevKnobs.decoderLatency` → `VideoRenderer(decoderTuning=)`) kartın `files:` listesinde yok → *Açık sorular*.

## Handoff

_(Ajan bitirince doldurur.)_

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulananlar:**
- **Açık sorular:**
