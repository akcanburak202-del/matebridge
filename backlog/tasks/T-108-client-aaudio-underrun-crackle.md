---
id: T-108
title: Tablet — Düşük gecikme (AAudio) seste oyun sırasında cızırtı; güvenli başlangıç tamponu, öğrenilen değeri hatırlama, boşalmada yumuşak geçiş
status: in-progress
phase: 5
owner: android-client-dev
depends_on: [T-101]
decisions: [0012]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/audio/
  - client-android/app/src/main/cpp/mbaudio.cpp
  - client-android/app/src/test/
  - backlog/tasks/T-108-client-aaudio-underrun-crackle.md
---

## Amaç

Kullanıcı bulgusu (2026-10-01/02, Witcher 2):
- "Düşük gecikme" ses çıkışında hafif cızırtı var, kalabalık uğultusu gibi sürekli seslerde duyuluyor.
- "Uyumlu" modda cızırtı yok.

Orkestratör log analizi (tablet `MB/audio ev=stats`, AAudio):
- `DriftController` güvenlik payı (safety) **5 ms** ile başlıyor ve her jitter-tampon boşalmasında (`underruns`) 5 ms büyüyor.
- Bir oturumda 5 dakikada 6 boşalma oldu (5→10→15→20→25→28→33 ms); `xruns=0`. Host tarafı temiz (`dropped=0`).
- Her boşalma bir tık. Sürekli seslerde cızırtı olarak duyuluyor.
- AudioTrack yolunda hedef ~21–22 ms ve boşalma yok.

## Kabul kriterleri

- [ ] AAudio yolunda safety başlangıcı güvenli bir değerdir: **20 ms**, sabit olarak adlandırılır. Kayıtlı öğrenilmiş değer varsa o kullanılır. AudioTrack yolu değişmez.
- [ ] **Öğrenilen safety hatırlanır.**
  - Oturum sonunda (ya da değiştikçe, seyrek) çıkış yoluna göre (aaudio/track) kalıcı saklanır. `audio/` paketinde kendi küçük deposu olur; `Settings.kt` ve `MainActivity` dokunulmaz, gerekiyorsa *Open questions*'a yazılır.
  - Sonraki bağlantı oradan başlar: `max(20 ms, kayıtlı)`.
  - Mevcut yavaş küçülme kuralı korunur.
  - Üst sınır mevcut 40 ms.
- [ ] **Boşalmada tık olmaz.**
  - Jitter tamponu boşalınca çıkış sert biçimde sıfıra düşmez: eldeki son örneklerle kısa bir sönüm (fade-out, mevcut `AudioRamp`) yapılır.
  - Yeniden başlarken fade-in olur.
  - Bugünkü davranış zaten böyleyse Plan'da kanıtıyla yazılır, tık kaynağı başka yerde aranır: AAudio callback'inde veri yokken ne yazılıyor?
- [ ] A/V senkronu bozulmaz (`av_offset_ms`, `audio_ms` mantığı aynı). Log alanlarına başlangıç safety'si ve kaynağı eklenir: `safety_init_ms=… source=default|stored`.
- [ ] Testler:
  - başlangıç değeri (varsayılan/kayıtlı);
  - kayıt ve geri okuma;
  - boşalmada çıkış örneklerinin sönümle sıfıra inmesi (ani sıçrama yok, en büyük örnek farkı sınırlı).
- [ ] `./scripts/check.sh` geçiyor. Cihaz testi orkestratörde (oyunda uğultulu sahne).

## Plan

**Tık kaynağı (kod incelemesi, kanıt):**
- AAudio'da geri çağrı yok (karar 0012 eki): yazıcı iş parçacığı her burst'ü `PlayoutCore.render` ile üretip bloklayan `write` ile yazar. Veri yokken (PRIMING) yazılan şey sıfırdır ve oraya her zaman sönümle (gain 0) gelinir. Native tarafta (`mbaudio.cpp`) veri yokken ayrıca bir şey yazılmıyor, xruns=0.
- Boşalmada sönüm zaten var: `PlayoutCore` PLAYING'de `level < need + fadeOut(3 ms)` olunca `AudioRamp.fadeOut(144)` yapar. Rezerv önceki burst'te garanti: PLAYING devam ettiyse seviye ≥ 144 kare kalmıştı. Sönüm, gerçek veri bitmeden 0'a iner. Yeniden başlarken `fadeIn(5 ms)` var.
- Yani tık sert bir örnek sıçraması değil. **Boşalmanın kendisi**: 3 ms sönüm, ardından ≥ target+span (~20–40 ms) sessizlik, ardından 5 ms yükseliş. Sürekli seste (kalabalık uğultusu) bu kısa delik "tık/cızırtı" olarak duyuluyor. Çözüm: boşalmayı önlemek (güvenli başlangıç + öğrenilen değer). Sönüm davranışı testle sabitlenir.

**Uygulama (yalnız `audio/` + test):**
1. `DriftController`:
   - `resetSafety(initialMs, floorMs)` eklenir. Safety bu değerle başlar.
   - Yavaş küçülme kuralı aynıdır (60 temiz pencerede 1 ms), alt sınırı `floorMs`. Üst sınır 40 ms.
   - Varsayılan kurucu davranışı (5 ms) değişmez; mevcut testler aynen geçer.
2. Yeni `SafetyMemory` (saf Kotlin) ve `SafetyStore` arayüzü:
   - Varsayılanlar `AAUDIO_DEFAULT_SAFETY_MS = 20` ve `TRACK_DEFAULT_SAFETY_MS = 5` (AudioTrack değişmez).
   - `initial(api) = max(varsayılan, kayıtlı)`, `source = stored` yalnız kayıtlı değer varsayılandan büyükse; değer [5, 40] aralığına kırpılır.
   - `onSafety(api, ms, nowMs)` değişince kaydeder, en sık 10 s'de bir. `flush(api, ms)` çıkış kapanırken/değişirken kaydeder.
   - AAudio'da küçülme alt sınırı 20 ms'dir (güvenli başlangıç). Öğrenilen fazlalık yavaşça 20'ye iner, 20'nin altına inip yeniden boşalma döngüsüne girmez (yorum: *Open questions*).
3. `SharedPrefsSafetyStore`:
   - `audio/` içinde, kendi dosyası `matebridge_audio` (anahtarlar `safety_ms_aaudio` / `safety_ms_track`), `apply()` ile.
   - `Settings.kt` / `MainActivity` dokunulmaz.
4. `AudioPlayout`:
   - Her çıkış açılışında api önceki çıkıştan farklıysa (ya da ilk açılışsa) önceki api'nin değeri kaydedilir ve drift safety'si yeni api'nin başlangıcıyla kurulur.
   - Aynı api'nin yeniden kurulumunda (routing/disconnected) öğrenilen değer korunur.
   - `audio_out` log satırına `safety_init_ms=… source=default|stored` eklenir. Saniyelik stats'ta değişiklik seyrek kaydedilir, akış sonunda (finally) son değer kaydedilir.
   - A/V (`av_offset_ms`, `audio_ms`) mantığına dokunulmaz.
5. Testler:
   - `SafetyMemoryTest`: varsayılan/kayıtlı başlangıç, kırpma, kayıt+geri okuma, seyrek kayıt.
   - `DriftControllerTest`: `resetSafety` ve alt sınır.
   - `UnderrunFadeTest`: `PlayoutCore`'u sabit DC ve sinüsle besleyip paketleri kesmek. Çıkış sönümle 0'a iner, en büyük ardışık örnek farkı ≤ genlik/144 + sinyal eğimi (sert kesimde ~genlik olurdu). Yeniden başlarken de aynı sınır. AAudio (240) ve AudioTrack (960) burst'leriyle.
6. Native (`mbaudio.cpp`): değişiklik gerekmiyor (yukarıdaki kanıt).

## Handoff
