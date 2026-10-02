---
id: T-114
title: Tablet — AAudio çıkış arabelleği varsayılanı 4 burst (20 ms); cızırtı deneyle doğrulandı. Çıkış payı ölçümü bu cihazda hep dolu görünüyor
status: done
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

- [x] `AudioBufferConfig.AAUDIO_DEFAULT_BURSTS = 4`. Kayıtlı büyümüş değer ve `--ei audio_buf_bursts` öncelik kuralları aynı kalır.
- [x] Çıkış payı ölçümü gerçek payı gösterecek biçimde düzeltilir:
  - ya `AAudioStream_getTimestamp` ile şimdiki okuma konumunu tahmin ederek (son timestamp + geçen süre × hız);
  - ya da yazım **öncesi** değil, bloklanan yazımın **döndüğü an** ölçerek.

  Plan'da hangisinin bu MMAP'te anlamlı olduğu gerekçelendirilir. Mümkün değilse ölçüm kaldırılmaz, `headroom_source=` ile yöntem loglanır ve kısıt *Handoff*'a yazılır.
- [x] `audio_ms` / A/V senkronu yeni varsayılanla doğru (+5 ms beklenir).
- [x] Testler güncellenir.
- [x] `./scripts/check.sh` geçiyor. Cihaz testi orkestratörde.

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

**A/V.** `audio_ms` cihaz sayaçlarından (`written − read` + cihaz gecikmesi) gelir. 4 burst varsayılanı doğrudan yansır: 2 → 4 burst = +480 kare (+10 ms). Test bunu doğrulayacak (`OutBufGrowthTest`, T-110 büyüme gecikmesi testinin yanında).

**Testler:**
- `HeadroomEstimatorTest`: ts tahmini, tutarsız ya da eksik ts → sayaç, sapan HAL konumunun ts payını düşürmesi.
- `HeadroomMeterTest`: kaynak ve sayaç min.
- `AudioBufferConfigTest` ve `OutBufMemoryTest`: varsayılan 4.
- `OutBufGrowthTest.theFourBurstDefaultIsSeenInTheAudioLatency`: 4 burst gecikmesi.

## Handoff

- **Commit:** 36844de (uygulama), fc7adbf (plan). Dal `task/T-114-client-aaudio-default-4-bursts`, `main` a23f2c8 üzerinden. Handoff ayrı bir commit'te.
- **check.sh:** ALL OK.
  - Yeni: `HeadroomEstimatorTest` (7).
  - `HeadroomMeterTest`: +3.
  - `OutBufGrowthTest`: +1, 4 burst gecikmesi.
  - `OutBufMemoryTest` ve `AudioBufferConfigTest` varsayılan 4'e göre güncellendi.

### Seçilen yöntem: zaman damgası
- MMAP'te `getFramesRead` ve bloklayan `write`'ın uyanması aynı istemci saat modelinden gelir. Bu model burst burst ilerler.
- Bu yüzden `written − read` iki noktada da ≈ `buf` çıkar. `write` dönüşünde tanım gereği tam `buf`; bu yüzden seçenek 2 anlamsız. `write` öncesinde de yazıcı tam bir burst kaçırmadıkça yine `buf`.
- HAL'in gerçek konumunu gösteren tek sinyal `getTimestamp`.
- Okuma tahmini: `tsPos + (now − tsNs) × 48000/1e9`. Pay = `framesWritten − tahmin`. Ölçüm her `write`'tan hemen önce yapılır.

### Değişen dosyalar
- `audio/HeadroomEstimator.kt` (yeni, saf, ayırmasız):
  - Kaynak `ts` olur, ancak zaman damgası varsa ve okuma sayacıyla T-101 aralığında tutarlıysa (gecikme −20…+100 ms). Değilse `counter`.
  - Sayaç payı (`written − read`) ayrıca tutulur.
- `audio/AAudioSink.kt`: `headroom()` artık mevcut `AAudioNative.counters` çağrısını kullanıyor. Önceden ayrılmış `LongArray` ile çalışır. `headroomCounter` ve `headroomFromTs` eklendi.
- `audio/AudioSink.kt`: `headroomCounter` ve `headroomFromTs` eklendi. Varsayılanlar: bilinmiyor / false (AudioTrack değişmedi).
- `cpp/mbaudio.cpp` ve `audio/AAudioNative.kt`: kullanılmayan T-110 `headroom` JNI'si kaldırıldı. `counters` yorumu güncellendi; artık her `write`'ta çağrılıyor.
- `audio/HeadroomMeter.kt`: `onWriteStart(headroom, now, counterHeadroom, fromTs)`. `Window`'a `counterMinFrames`, `tsSamples`, `knownSamples` ve `source` (`ts|counter|mixed|-`) eklendi.
- `audio/AudioPlayout.kt`: `ev=stats` ve `audio_buffer_grow` satırlarına `headroom_source=… out_headroom_counter_min_frames=…` eklendi. `out_headroom_min_frames` ve `p5` artık birincil (ts) değer.
- `audio/AudioBufferConfig.kt`: `AAUDIO_DEFAULT_BURSTS = 4`.
- `audio/OutBufGrowth.kt`: yalnız belge yorumu. Kural aynı, girdisi artık ts tabanlı pay.

### Varsayımlar / kısıtlar
- **Sunum gecikmesi sapması:** `getTimestamp` sunum konumu verirse (HAL donanım zaman damgası), ts payı cihazın sunum gecikmesi kadar yüksek çıkar.
  - Yaklaşık değer: `out_headroom_min_frames − out_headroom_counter_min_frames`.
  - Büyüme kuralı bu yüzden temkinli tarafta kalır: yanlış büyüme yerine geç büyüme. Bir kez büyüyen değer kalıcı olarak kaydedildiği için bu taraf seçildi.
  - Zaman damgası saf MMAP DMA konumuysa sapma ≈ 0 olur.
- Zaman damgası sayaçtan 20 ms'ten fazla ilerideyse ya da 100 ms'ten fazla gerideyse güvenilmez sayılır ve sayaç payı kullanılır (`headroom_source=counter|mixed`). Böylece bozuk bir zaman damgası yanlış büyüme tetikleyemez.
- **Kayıtlı değerler:** T-110 sırasında kaydedilmiş 2–3 burst artık varsayılanın altında kalır ve başlangıç `buf_source=default` olur. 5–6 kayıtlıysa o kullanılır (kural değişmedi).
- **A/V:** kart "+5 ms" diyor. Hesap ise 2 → 4 burst = +480 kare = **+10 ms** `audio_ms` veriyor. `av_offset_ms` de en çok ~10 ms artar. Önceki ses priming bekletmesiyle videoyu bekliyorduysa artış daha az olur.
- Her `write` başına ek maliyet: `getTimestamp` + iki sayaç + `clock_gettime` (MMAP'te IPC yok). Önceden yalnız iki sayaç okunuyordu.

### Test edilmeyenler (cihaz gerekli)
- Bu HAL'de `getTimestamp`'in ne kadar sık güncellendiği ve ts payının gerçek değerleri.
- `headroom_source` değerinin gerçekten `ts` olup olmadığı.
- Oyun modunda 4 burst varsayılanıyla cızırtının olmadığı (deney yalnız `--ei` ile yapıldı).

### Tablette kontrol edilecekler
1. Normal açılış, `--ei` yok: `adb logcat -s 'MB:*' | grep -E 'audio_out|audio_buffer_grow|ev=stats'`.
   - `audio_out` satırı: `buf_bursts_init=4 buf_source=default buf=960`. Eski kayıt 5–6 ise `stored`.
2. `ev=stats` satırları:
   - `headroom_source=ts` (çoğunlukla) olmalı.
   - `out_headroom_counter_min_frames` ≈ 960 olmalı.
   - `out_headroom_min_frames` ≈ 960 + sunum gecikmesi olmalı ve saniyeden saniyeye biraz oynamalı. Hep tam 960 ise zaman damgası sayaçla aynı modelden geliyordur.
   - `headroom_source=counter` görünürse ts kullanılamıyor demektir: bulgu olarak not edilmeli.
3. Oyun modu, uğultulu sahne, Düşük gecikme ses:
   - Cızırtı olmamalı.
   - `out_headroom_min_frames` / `p5` düşüşleri izlenmeli. 240'ın altına inerse `audio_buffer_grow reason=headroom headroom_source=ts` beklenir.
4. `audio_ms` T-110'a göre ~+10 ms (2 → 4 burst) olmalı. `av_offset_ms` makul kalmalı.
5. Masaüstü kullanımında birkaç dakika boyunca `audio_buffer_grow` çıkmamalı (yanlış büyüme yok).

### Open questions
- Kartta beklenen "+5 ms", 2 → 4 burst için hesapla uyuşmuyor (+10 ms). Orkestratör doğrulamalı.
