---
id: T-110
title: Tablet — Düşük gecikme (AAudio MMAP) seste oyun modunda sürekli cızırtı; çıkış payı ölçümü ve uyarlamalı çıkış arabelleği
status: done
phase: 5
owner: android-client-dev
depends_on: [T-108]
decisions: [0012]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/audio/
  - client-android/app/src/main/cpp/mbaudio.cpp
  - client-android/app/src/test/
  - backlog/tasks/T-110-client-aaudio-mmap-headroom.md
---

## Amaç

Kullanıcı bulgusu (2026-10-02 ~00:29, T-108 kurulduktan sonra):
- Oyun modunda, Düşük gecikme seste, kalabalık uğultulu sahnede **sürekli cızırtı**. Kullanıcı bunu kısa tık değil, sürekli olarak tarif etti.
- Uyumlu modda (AudioTrack) cızırtı yok.

Orkestratör analizi:
- O anlarda jitter-tampon boşalması yalnızca 3 tane (tek tek kesintiler). Sürekli cızırtıyı açıklamaz.
- Host sesi düzenli gönderiyor (`packets=100/s`, `dropped=0`).
- AAudio MMAP exclusive çıkış arabelleği `buf=480` kare (10 ms = 2 burst).
- `xruns=0` her zaman: bu HAL'de `AAudioStream_getXRunCount` MMAP taşmalarını muhtemelen bildirmiyor. Bu yüzden mevcut "xrun olunca bir burst büyüt" kuralı hiç tetiklenmiyor.
- Hipotez:
  - Oyun modunda (120 fps çözme, jitter 0) yazıcı iş parçacığı zaman zaman 5 ms'lik süreyi kaçırıyor.
  - MMAP halkası boşalınca donanım eski veriyi yeniden çalıyor; sürekli seste bu cızırtı olarak duyuluyor.
  - AudioTrack'in arabelleği daha büyük olduğu için orada duyulmuyor.

Deney (kullanıcıyla, **yapılmadı**, 2026-10-02 sabah yapılacak):
- `am start -S -n dev.matebridge.client/.MainActivity --ei audio_buf_bursts 4` (`buf=960`, 20 ms) ile aynı sahne.
- Cızırtı kaybolursa hipotez doğrulanır.

## Kabul kriterleri

- [x] **Ölçüm.** Her yazımda çıkış payı ölçülür: `AAudioStream_getFramesWritten − getFramesRead`, ya da timestamp'ten okuma konumu. Saniyelik `ev=stats` satırına şunlar eklenir:
  - `out_headroom_min_frames`
  - `out_headroom_p5_frames`
  - `write_gap_ms_max` (iki yazım arası en uzun süre)
  - `underflow_est` (payın ≤ 0 göründüğü yazım sayısı)

  Ölçüm yolu ayırmaz, kilitlemez, loglamaz (mbaudio.cpp kuralları).
- [x] **Uyarlamalı çıkış arabelleği.** Pay bir burst'ün altına inerse ya da `underflow_est > 0` ise çıkış arabelleği bir burst büyür (`setBufferSizeInFrames`).
  - Üst sınır kapasite ya da 6 burst.
  - Bir kez büyüyen değer o çıkış yolu için T-108'deki `SafetyMemory` deposuna benzer biçimde saklanır ve sonraki bağlantı oradan başlar.
  - Küçülme yok ya da çok yavaş.
  - `--ei audio_buf_bursts` verilmişse başlangıç odur.
- [x] Mevcut xrun kuralı korunur (bildiren cihazlar için).
- [x] A/V hesabı yeni arabellek boyunu hesaba katar (`audio_ms` doğru kalır).
- [x] Testler:
  - pay hesabının saf mantığı (sahte sayaçlarla);
  - büyüme kuralı ve sınırı;
  - saklama/geri okuma.
- [ ] `./scripts/check.sh` geçiyor. Cihaz testi kullanıcıyla: oyun modunda uğultulu sahne, önce deney, sonra bu sürüm.

## Plan

**Ölçüm noktası.** Yazıcı her burst'ü bloklayan `write` ile yazar. `write`, son kareyi yazınca döner; o anda halka ≈ `buf` dolu. Pay en düşük noktasına bir sonraki `write` çağrısından hemen önce iner. Bu yüzden pay her `write`'tan **hemen önce** ölçülür: `getFramesWritten − getFramesRead` (MMAP'te okuma sayacı saat modelinden gelir, IPC yok).
- Normalde pay ≈ `buf` olur. Pay `< burst` ise yazıcı `write` dışında bir burst'ten fazla kaldı demektir (ramak kala). Pay `≤ 0` ise okuma yazmayı geçti (tahmini boşalma).

**Native (`mbaudio.cpp`):** yeni `AAudioNative.headroom(handle): Long` = written − read. Ayırma, kilit, log ve yukarı çağrı yok. Hata ya da null handle için `Long.MIN_VALUE` döner.

**Saf Kotlin (yeni, `audio/`):**
1. `HeadroomMeter`
   - Önceden ayrılmış `IntArray` ile çalışır; yazım yolunda ayırma yok.
   - `onWriteStart(headroom, nowNs)`, `onWriteEnd(nowNs)`.
   - Pencere sonunda (`window()`, saniyede bir): `min`, `p5` (sıralama yerinde, kopya dizide insertion sort, yalnız stats anında), `underflowEst` (pay ≤ 0 sayısı), `gapMaxNs` (iki `write` başlangıcı arası en uzun süre) ve `busyMaxNs` (`write` dönüşü → sonraki `write`, yazıcının kendi gecikmesi). Ardından sıfırlanır.
   - Pay bilinmiyorsa (AudioTrack) yalnız süreler tutulur.
2. `OutBufGrowth.decide(window, xrunDelta, burst, bufFrames, maxFrames, warm)` → büyüme nedeni ya da null.
   - Nedenler: `underflow` (`underflowEst > 0`), `headroom` (`min < burst`), `xrun` (mevcut kural, bildiren cihazlar için).
   - Açılıştan sonraki ilk pencere (`warm=false`, mevcut `xrunBase` mantığı) yok sayılır.
   - Pencere başına en çok bir burst; üst sınır `min(kapasite, 6 burst)` (`AAudioSink.maxBufFrames`, değişmez). Küçülme yok.
3. `OutBufMemory(store)` ve `OutBufStore` arayüzü
   - Başlangıç: `--ei audio_buf_bursts` verilmişse o (`source=override`); değilse `max(varsayılan 2, kayıtlı)`, [1, 6] aralığına kırpılır (`source=stored|default`).
   - `onGrown(path, bursts)`: kayıtlıdan büyükse hemen kaydeder (seyrek olay: oturumda en çok 5 kez). Değer tekdüze artar.
   - Anahtar çıkış yoluna göre: `aaudio_exclusive` / `aaudio_shared` (istenen seçenek).
   - AudioTrack kaydedilmez; davranışı değişmez (yalnız xrun kuralı).
4. `SharedPrefsOutBufStore`: T-108 ile aynı dosya `matebridge_audio`, anahtar `out_buf_bursts_<path>`, `apply()` ile.

**`AudioSink` / `AAudioSink`:** `headroom(): Long`. Varsayılan `Long.MIN_VALUE` (bilinmiyor; AudioTrack). `AAudioSink.capacity`/`maxBufFrames` loglanır.

**`AudioPlayout`:**
- AAudio açılışında başlangıç burst sayısı `OutBufMemory`'den gelir. `audio_out` satırına `buf_bursts_init=… buf_source=override|stored|default buf_stored=…` eklenir.
- Döngüde her `write` öncesi `headroom` + `nanoTime`, sonrasında `nanoTime` alınır.
- Saniyelik stats'ta pencere okunur, `OutBufGrowth` uygulanır (xrun kuralı onun içinde korunur). Büyürse `audio_buffer_grow … reason=…` loglanır ve AAudio'da kaydedilir.
- `ev=stats`'a `out_headroom_min_frames`, `out_headroom_p5_frames`, `write_gap_ms_max`, `write_busy_ms_max`, `underflow_est` eklenir. AudioTrack'te pay alanları `-`.

**A/V:** AAudio oynatma konumu cihazın kendi sayaçlarından gelir (`OutputClock.onDeviceCounters`). Yeni frame'in gecikmesi = (written − read) + cihaz gecikmesi; büyüyen arabellek fazladan yazılan kareler olarak `written`'a doğrudan yansır, `audio_ms` kendiliğinden doğru kalır. Büyümeden sonra bir sonraki zaman damgası hemen okunur (`nextTsAt` sıfırlanır). Test: sahte sayaçlarla büyüme sonrası gecikmenin tam bir burst arttığı.

**Testler:** `HeadroomMeterTest` (min/p5/underflow/gap/busy, pencere sıfırlama, taşma, bilinmeyen pay), `OutBufGrowthTest` (nedenler, ısınma, sınır), `OutBufMemoryTest` (varsayılan/kayıtlı/override, kırpma, tekdüze kayıt, yol başına ayrı), `OutputClockTest`'e büyüme sonrası gecikme testi.

## Handoff

- **Commit:** e3867fe (uygulama), dad976c (plan). Dal `task/T-110-client-aaudio-mmap-headroom`, `main` 8ff0d4a üzerinden.
- **check.sh:** ALL OK. Yeni testler: `HeadroomMeterTest` 8, `OutBufGrowthTest` 8, `OutBufMemoryTest` 10.

### Değişen dosyalar
- `cpp/mbaudio.cpp`: `AAudioNative_headroom` = `getFramesWritten − getFramesRead`. Okuma sayacı sonra okunur; değer ya doğru ya biraz küçük çıkar (temkinli taraf). Ayırma, kilit ve log yok.
- `audio/AAudioNative.kt`: `headroom()`.
- `audio/AudioSink.kt`: `headroom()`, varsayılanı `HEADROOM_UNKNOWN` (AudioTrack).
- `audio/AAudioSink.kt`: `headroom()`, `maxFrames`; `audio_out` satırına `max_buf=` eklendi.
- `audio/HeadroomMeter.kt` (yeni, saf):
  - Yazım başına örnek önceden ayrılmış diziye yazılır.
  - Saniyelik pencere: min, p5 (nearest-rank), `underflow_est`, `write_gap_ms_max` (iki `write` başlangıcı arası), `write_busy_ms_max` (`write` dönüşü → sonraki `write`).
- `audio/OutBufGrowth.kt` (yeni, saf): nedenler `underflow` > `headroom` (< 1 burst) > `xrun`. İlk pencere yok sayılır. Pencere başına 1 burst, üst sınır `min(kapasite, 6 burst)`.
- `audio/OutBufMemory.kt` (yeni, saf) ve `OutBufStore`:
  - Başlangıç: override, yoksa `max(2, kayıtlı)`.
  - Kayıtlı değer yalnız artar.
  - Yol anahtarı istenen seçenektir: `aaudio_exclusive` / `aaudio_shared`.
- `audio/SharedPrefsOutBufStore.kt` (yeni): dosya `matebridge_audio`, anahtar `out_buf_bursts_<path>`.
- `audio/AudioPlayout.kt`:
  - Her `write` öncesi ve sonrası ölçüm.
  - Saniyelik büyüme kararı. `audio_buffer_grow` satırına `reason=… bursts=… saved=…` eklendi.
  - Büyümeden sonra zaman damgası hemen yeniden okunur.
  - `audio_out` satırına `buf_bursts_init=… buf_source=override|stored|default buf_stored=…` eklendi.
  - `ev=stats` satırına `out_headroom_min_frames`, `out_headroom_p5_frames`, `underflow_est`, `write_gap_ms_max`, `write_busy_ms_max` eklendi. AudioTrack'te pay alanları `-`.
- `audio/AudioBufferConfig.kt`: yalnız belge yorumu.

### Varsayımlar
- Pay, `write` çağrısından hemen önce ölçülür. Bloklayan `write` dönerken halka ≈ `buf` dolu olur, en düşük nokta bir sonraki çağrıdan hemen öncedir.
  - Sağlıklı durumda `out_headroom_min_frames` ≈ `buf_frames` (480), `write_gap_ms_max` ≈ 5–6 ms.
  - Payın burst'ün altına inmesi yazıcının bir burst'ten uzun süre `write` dışında kaldığını gösterir.
- MMAP'te `getFramesRead` saat modelinden gelir. Bu tahmin ±1 burst oynayabilir. Bu yüzden `headroom` nedeni katı `< burst` olarak tanımlandı; tam 1 burst (240) büyütmez.
- **Küçülme yok:** ne oturum içinde ne kayıtta. En kötü durumda bir AAudio yolu kalıcı olarak 6 burst'e (30 ms, +20 ms gecikme) çıkar. Sıfırlamak için uygulama verisi silinir ya da `matebridge_audio` içindeki `out_buf_bursts_*` anahtarı kaldırılır.
- `--ei audio_buf_bursts` verilse bile büyüme, kayıtlıdan büyükse kaydedilir. Kayıt tekdüze arttığı için deney sonraki normal açılışları en çok o büyümüş değere çeker.
- AudioTrack davranışı değişmedi: pay ölçülmez, yalnız xrun kuralı çalışır, kayıt tutulmaz. Sınırı kendi `grow()`'u koyar.
- A/V: AAudio konumu cihaz sayaçlarından geldiği için büyüyen arabellek `audio_ms`'e doğrudan yansır (fazladan yazılan burst). Test `OutBufGrowthTest.aGrownBufferIsSeenInTheAudioLatency`.

### Test edilmeyenler (cihaz gerekli)
- Gerçek MMAP akışında `getFramesRead`'in nasıl davrandığı (sürekli mi, burst burst mı) ve payın gerçek değerleri.
- Büyümenin cızırtıyı gidermesi.
- SharedPreferences kaydının oturumlar arası kalıcılığı.

### Tablette kontrol edilecekler
1. **Önce deney (kartın Amaç'ı):** `am start -S -n dev.matebridge.client/.MainActivity --ei audio_buf_bursts 4`.
   - `audio_out` satırında `buf_bursts_init=4 buf_source=override buf=960` olmalı.
   - Oyun modunda uğultulu sahne: cızırtı kayboluyor mu?
   - Not: bu koşuda büyüme olursa 4'ün üstü kaydedilir.
2. **Normal açılış:** `adb logcat -s 'MB:*' | grep -E 'audio_out|audio_buffer_grow|ev=stats'`.
   - İlk bağlantıda `buf_bursts_init=2 buf_source=default` olmalı.
   - Stats'ta normalde `out_headroom_min_frames` ≈ 400–480, `underflow_est=0`, `write_gap_ms_max` ≈ 5–6, `write_busy_ms_max` küçük.
3. **Oyun modunda uğultulu sahne, Düşük gecikme:**
   - Cızırtı anlarında `out_headroom_min_frames` < 240 ya da `underflow_est` > 0 görünüyor mu? `write_busy_ms_max` / `write_gap_ms_max` sıçrıyor mu?
   - Ardından `audio_buffer_grow … reason=headroom|underflow saved=1` gelip cızırtı kesiliyor mu?
   - `audio_ms` bir burst başına ~5 ms artmalı, `av_offset_ms` makul kalmalı.
4. Büyüme olduysa uygulamayı kapatıp yeniden bağlan: `buf_source=stored buf_stored=<n>` ve `buf=<n×240>` olmalı.
5. Pay hep ≈ `buf` ise ve yine de cızırtı varsa hipotez yanlıştır: sorun yazıcının geç kalması değil. O durumda `getFramesRead` ham değerleri `audio_clock_raw` satırıyla karşılaştırılmalı.

### Open questions
- `write_busy_ms_max` saniyelik stats penceresini de içerir. Log satırı yazıcı iş parçacığında, iki `write` arasında kuruluyor (T-108 öncesinden beri böyle). Busy her saniye bir kez sıçrıyorsa olası düzeltme loglamayı yazıcıdan almak olur. Bu ayrı bir kart konusu; bu kartta dokunulmadı.
- Küçülme olmaması bilinçli bir seçim (kart "yok ya da çok yavaş" diyor). Orkestratör isterse sonraki bir kartta kayıtlı değer için yavaş bir azalma eklenebilir.
