---
id: T-114
title: Tablet — AAudio çıkış arabelleği varsayılanı 4 burst (20 ms); cızırtı deneyle doğrulandı. Çıkış payı ölçümü bu cihazda hep dolu görünüyor
status: todo
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

(ajan doldurur)

## Handoff
