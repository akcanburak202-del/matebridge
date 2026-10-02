---
id: T-114
title: Tablet — AAudio çıkış arabelleği varsayılanı 4 burst (20 ms); cızırtı deneyle doğrulandı. Çıkış payı ölçümü bu cihazda hep dolu görünüyor
status: in_progress
phase: 5
owner: android-client-dev
depends_on: [T-110]
decisions: [0012]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/audio/
  - client-android/app/src/main/cpp/mbaudio.cpp
  - client-android/app/src/test/
  - backlog/tasks/T-114-client-aaudio-default-4-bursts.md
---

## Amaç

Kullanıcı deneyi (2026-10-02 ~07:50):
- `--ei audio_buf_bursts 4` (`buf=960`, 20 ms) ile oyun modunda, Düşük gecikme seste, uğultulu sahnede **cızırtı olmadı**. Önceki 2 burst (10 ms) ile sürekli cızırtı vardı.
- Hipotez (T-110) doğrulandı: 10 ms MMAP arabelleği oyun yükünde yetmiyor.

T-110 ölçümü bu cihazda işe yaramıyor:
- 20 ms'lik oturum boyunca her saniye `out_headroom_min_frames=960` (= arabellek boyu), `underflow_est=0`, `write_gap_ms_max` 5,4–6,3 ms.
- Blokajlı yazım arabelleği hep dolu tuttuğu için `framesWritten − framesRead` her ölçümde tam arabellek gösteriyor. Uyarlamalı büyüme bu yüzden tetiklenemez.

## Kabul kriterleri

- [ ] `AudioBufferConfig.AAUDIO_DEFAULT_BURSTS = 4`. Kayıtlı büyümüş değer ve `--ei audio_buf_bursts` öncelik kuralları aynı kalır.
- [ ] Çıkış payı ölçümü gerçek payı gösterecek biçimde düzeltilir:
  - ya `AAudioStream_getTimestamp` ile şimdiki okuma konumunu tahmin ederek (son timestamp + geçen süre × hız);
  - ya da yazım **öncesi** değil, bloklanan yazımın **döndüğü an** ölçerek.

  Plan'da hangisinin bu MMAP'te anlamlı olduğu gerekçelendirilir. Mümkün değilse ölçüm kaldırılmaz, `headroom_source=` ile yöntem loglanır ve kısıt *Handoff*'a yazılır.
- [ ] `audio_ms` / A/V senkronu yeni varsayılanla doğru (+5 ms beklenir).
- [ ] Testler güncellenir.
- [ ] `./scripts/check.sh` geçiyor. Cihaz testi orkestratörde.

## Plan

**Varsayılan.** `AudioBufferConfig.AAUDIO_DEFAULT_BURSTS = 4`. `OutBufMemory` kuralları aynı: override > max(varsayılan, kayıtlı). Eski T-110 kaydı (2–3) artık varsayılanın altında kalır, `source=default` olur.

**Yöntem seçimi: zaman damgası (seçenek 1).** Gerekçe:
- MMAP'te `getFramesRead` istemcinin kendi saat modelinden gelir. Bu model burst burst ilerler. Bloklayan `write` de aynı modelle uyanır: model "bir burst okundu" deyince uyanır, o burst'ü doldurur ve döner.
- Bu yüzden `written − read` dönüş anında tanım gereği tam `buf` olur (seçenek 2 bu MMAP'te anlamsız). `write` öncesinde de yazıcı bütün bir burst geç kalmadıkça `buf` olur. Cihazdaki "hep 960" bulgusu bununla uyumlu.
- Gerçek DSP konumunu yansıtan tek sinyal HAL'den gelen `AAudioStream_getTimestamp`. Okuma konumu tahmini: `tsPos + (now − tsNs) × 48000 / 1e9`. Pay = `framesWritten − tahmin`.
- Ölçüm noktası yine `write` öncesi (en düşük nokta).

**Kısıt (Handoff'a da yazılacak).** Zaman damgası sunum konumuysa, payda cihazın sabit sunum gecikmesi kadar artı sapma olur (temkinli: yanlış büyüme yerine geç büyüme). Bu yüzden sayaç payı da ayrıca loglanır. İkisinin farkı ≈ zaman damgası gecikmesidir. Farkın dalgalanması, HAL konumunun istemci modelinden saptığını gösterir.

**Uygulama:**
- `HeadroomEstimator` (yeni, saf):
  - `estimate(written, read, tsPos, tsNs, now)` → pay.
  - Kaynak `ts` olur, ancak zaman damgası varsa ve okuma sayacıyla tutarlıysa (T-101 aralığı `OutputClock.MIN_LAG_US..MAX_LAG_US`). Değilse `counter` (eski yöntem).
  - Ayırma yok. Son sayaç payı ve kaynak alanlarda tutulur.
- `AAudioSink.headroom()`: mevcut `AAudioNative.counters` çağrısıyla, önceden ayrılmış diziyle. Native `headroom` artık kullanılmadığı için `mbaudio.cpp` ve `AAudioNative.kt`'den kaldırılır.
- `AudioSink`: `headroomCounter` (son sayaç payı) ve `headroomFromTs` eklenir. Varsayılanlar: bilinmiyor / false.
- `HeadroomMeter.onWriteStart(headroom, now, counterHeadroom, fromTs)`. Pencereye `counterMinFrames` ve `source` (`ts|counter|mixed`) eklenir.
- `ev=stats` satırına `headroom_source=…` ve `out_headroom_counter_min_frames=…` eklenir. `audio_buffer_grow` satırına `headroom_source=` eklenir.
- `OutBufGrowth` aynı kalır; `headroomMinFrames` artık ts tabanlı.

**A/V.** `audio_ms` cihaz sayaçlarından (`written − read` + cihaz gecikmesi) gelir. 4 burst varsayılanı doğrudan yansır: 2 → 4 burst = +480 kare (+10 ms). Test bunu doğrulayacak (OutputClockTest).

**Testler:**
- `HeadroomEstimatorTest`: ts tahmini, tutarsız ya da eksik ts → sayaç, sapan HAL konumunun ts payını düşürmesi.
- `HeadroomMeterTest`: kaynak ve sayaç min.
- `AudioBufferConfigTest` ve `OutBufMemoryTest`: varsayılan 4.
- `OutputClockTest`: 4 burst gecikmesi.

## Handoff
