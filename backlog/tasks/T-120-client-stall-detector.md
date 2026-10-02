---
id: T-120
title: Tablet — süreç donma dedektörü (yüksek öncelikli tik iş parçacığı); ses/görüntü varış boşluklarının tabletten mi geldiğini ayır
status: done
phase: 5
owner: android-client-dev
depends_on: [T-117]
decisions: []
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/diag/
  - client-android/app/src/main/kotlin/dev/matebridge/client/session/SessionController.kt
  - client-android/app/src/test/
  - backlog/tasks/T-120-client-stall-detector.md
---

## Amaç

Cihaz testi (2026-10-02 ~10:30, NOTES'a eklenecek). Apple Music dinlerken 1–2 dakikada bir, kümeler hâlinde, **ses ve görüntü birlikte** 60–250 ms geç varıyor:
- `audio_arrival_gap` `gap_ms` 160/253, `owd_ms` 159/247, `per_read` 5–10;
- aynı anda `MB/render` `net_p99_us` 130–270 ms, ping RTT 3 → 143 ms.

Host bu anlarda sesi düzenli yazıyor: `write_int_ms_max` ≤ 18, `pending_bytes=0`. Video bit hızı düşük (2–5 Mbps). Kullanıcıya göre Wi-Fi'de de aynı sıklıkta oluyor, yani adb USB tüneli değil.

Kalan adaylar:
- (a) tablet sürecinin ya da çekirdeğin tamamen durması (zamanlama, güç yönetimi, Huawei dondurma);
- (b) Mac çekirdeğinin iki bağlantıda birden göndermeyi geciktirmesi.

Bu kart (a)'yı ölçer. Davranışı değiştirmez.

## Kapsam dışı

- Düzeltme (nedene göre ayrı kart).
- Mac tarafı paket yakalama (orkestratör `tcpdump` ile ayrıca bakabilir).

## Kabul kriterleri

- [ ] Oturum süresince çalışan tek bir tanı iş parçacığı vardır:
  - öncelik `THREAD_PRIORITY_URGENT_AUDIO` ya da mümkün olan en yüksek;
  - her 5 ms'de `SystemClock.elapsedRealtimeNanos()` ve `uptimeNanos` okur;
  - beklenen uyanmadan **> 30 ms** gecikirse olay kaydeder.

  `elapsedRealtime − uptime` farkındaki değişim, cihazın derin uykuya / askıya alınmaya girip girmediğini ayırır.
- [ ] Ayrıca kontrol ve video okuyucularının son `read()` dönüşü (T-117 alanları) ile karşılaştırma yapılır. Bir ses varış boşluğu (> 50 ms) olduğunda o pencerede tik iş parçacığının en büyük gecikmesi `audio_arrival_gap` satırına `tick_late_ms=` olarak eklenir. Yorum: tik de geciktiyse süreç/CPU donmuş; tik zamanında ise veri gerçekten geç gelmiş (ağ yığını ya da Mac).
- [ ] Saniyelik bir `MB/session` ya da `MB/diag` `ev=stall_stats` satırı: `tick_late_max_ms`, `stalls` (> 30 ms sayısı), `suspend_ms` (uptime/realtime farkı), `cpu_freq_khz` (okunabiliyorsa `/sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq`, en büyük çekirdek, opsiyonel). Ayrıca bir `I` seviyesinde `ev=stall dur_ms=` satırı yazılır (> 50 ms ise, saniyede en çok 5).
- [ ] Maliyet: iş parçacığı yalnız oturum açıkken çalışır, ayırma yapmaz, CPU yükü ihmal edilebilir. Plan'da tahmini yazılır (5 ms uyanma = 200 Hz).
- [ ] Hesap saf Kotlin, birim testli (sahte saat).
- [ ] `./scripts/check.sh` geçiyor. Cihaz testi orkestratörde.

## Plan

1. **Saf sınıf `diag/StallMeter.kt`** (JVM birim testli, tik yolunda ayırma yok, `synchronized`):
   - Saatler: tekdüze saat = `System.nanoTime()` (Android'de `CLOCK_MONOTONIC` = uptime; askıda ilerlemez, T-117'nin `readNs`'iyle aynı saat). `minSdk 29`'da `SystemClock.uptimeNanos()` yok (API 35). Gerçek saat = `SystemClock.elapsedRealtimeNanos()` (`CLOCK_BOOTTIME`, askıda ilerler). Fark (`realtime − uptime`) yalnız askıda artar.
   - `start(nowNs, realtimeNs)`, `stop()`, `nextDeadlineNs()`.
   - `onTick(nowNs, realtimeNs)`: gecikme = now − beklenen uyanma. Pencereye işlenir (`tick_late_max`, `stalls` > 30 ms, `ticks`). Askı farkı tik başına alınır. Sonraki uyanma beklenen + 5 ms; gecikme 5 ms'yi aştıysa now + 5 ms (kaçan tikler toplanmaz). Gecikme > 50 ms ise `true` döner (saniyede en çok 5; ayrıntı yeniden kullanılan `Stall` nesnesinde, `suppressed` sayacı ile).
   - Son 256 tikin halkası: (uyanma anı, gecikme). 200 Hz'de ≥ 1,28 s; T-117 boşlukları ≤ 1 s.
   - `maxLateUs(fromNs, toNs, nowNs)`: [from, to] penceresiyle örtüşen tiklerin en büyük gecikmesi. Bir tikin "durmuş" aralığı [uyanma − gecikme, uyanma]. Henüz uyanmamış ama gecikmiş tik de sayılır (now − beklenen): süreç birlikte uyandıysa okuyucu tik iş parçacığından önce loglayabilir. Dedektör kapalıysa ya da kapsam yoksa `NONE` (`-`).
   - `takeWindow(out)`: saniyelik pencere. `suspend_ms` = penceredeki fark değişimi.
2. **`diag/StallDetector.kt`** (Android):
   - `start()`/`stop()` idempotent. İş parçacığı `mb-stall`, daemon.
   - Öncelik: `THREAD_PRIORITY_URGENT_AUDIO`; reddedilirse `THREAD_PRIORITY_AUDIO`. Elde edilen değer `ev=stall_detector_start prio=` satırına yazılır.
   - Döngü: `LockSupport.parkNanos` ile beklenen uyanmaya kadar (erken dönüşte tekrar). Sonra `nanoTime` + `elapsedRealtimeNanos` → `meter.onTick`.
   - Saniyede bir `I diag ev=stall_stats ticks= tick_late_max_ms= stalls= suspend_ms= cpu_freq_khz=` satırı. `cpu_freq_khz` = `/sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq` en büyüğü. Okunamazsa `-` ve bir daha denenmez. Dosya listesi başlangıçta bir kez çıkarılır.
   - Donma > 50 ms: `I diag ev=stall dur_ms= suspend_ms= ctl_idle_ms= video_idle_ms= suppressed=`. `*_idle_ms` = tespit anı − kontrol/video okuyucunun son `read()` dönüşü (T-117 alanları).
   - Dizgi işi yalnız saniyelik satırda ve donma satırında.
3. **`SessionController`**:
   - `@Volatile lastControlReadNs` (güncel bağlantı, veri dolu `read()`).
   - Dedektör `OpenControl`/`PromoteCandidate`'de başlar; `CloseControl`'de ve motor kapanışında durur. Yani yalnız kontrol bağlantısı varken çalışır.
   - `audio_arrival_gap` satırına `tick_late_ms=` eklenir = `meter.maxLateUs(readNs − gap, readNs, now)`.
4. **Maliyet tahmini:** 200 uyanma/s × ~10–20 µs (park + iki saat okuması + kısa kilit) ≈ tek çekirdeğin %0,2–0,4'ü. Bir de saniyede bir sysfs okuması ve log satırı. Tik yolunda ayırma yok. Yayın sırasında CPU zaten 60–120 Hz video ile uyanık; ek enerji etkisi küçük beklenir.
5. Testler: `client-android/app/src/test/kotlin/dev/matebridge/client/diag/StallMeterTest.kt` (sahte saat).

## Handoff

- **Commit:** `15a4ac0` (uygulama), plan `9674af5`. Dal: `task/T-120-client-stall-detector`.
- **Dokunulan dosyalar:**
  - `client-android/app/src/main/kotlin/dev/matebridge/client/diag/StallMeter.kt` (yeni, saf hesap)
  - `client-android/app/src/main/kotlin/dev/matebridge/client/diag/StallDetector.kt` (yeni, `mb-stall` iş parçacığı + loglar)
  - `client-android/app/src/main/kotlin/dev/matebridge/client/session/SessionController.kt` (başlat/durdur, `lastControlReadNs`, `tick_late_ms`)
  - `client-android/app/src/test/kotlin/dev/matebridge/client/diag/StallMeterTest.kt` (14 test, sahte saat)
- **LOGGING.md için yeni alanlar (orkestratör ekler), bileşen `diag`, etiket `MB/diag`:**
  - `I diag ev=stall_detector_start prio= period_ms=5 cpu_freq_files=`: `prio` = iş parçacığının elde ettiği öncelik (-19 = URGENT_AUDIO, -16 = AUDIO). `cpu_freq_files` = okunabilir `scaling_cur_freq` dosya sayısı. Kapanışta `ev=stall_detector_stop`.
  - Saniyede bir `I diag ev=stall_stats ticks= tick_late_max_ms= stalls= suspend_ms= cpu_freq_khz=`:
    - `ticks`: penceredeki tik sayısı (beklenen ~200);
    - `tick_late_max_ms`: beklenen uyanmaya göre en büyük gecikme;
    - `stalls`: > 30 ms gecikmeli tik sayısı;
    - `suspend_ms`: penceredeki `elapsedRealtime − uptime` artışı (cihaz askıda geçen süre);
    - `cpu_freq_khz`: tüm çekirdeklerin `scaling_cur_freq` en büyüğü; okunamazsa `-`.
  - `I diag ev=stall dur_ms= suspend_ms= ctl_idle_ms= video_idle_ms= suppressed=` (tik > 50 ms geç, saniyede en çok 5):
    - `suspend_ms`: o tik aralığında askı süresi;
    - `*_idle_ms`: tespit anı − kontrol/video okuyucunun son veri dolu `read()` dönüşü (`-` = henüz yok);
    - `suppressed`: hız sınırına takılan donma sayısı.
  - `D audio ev=audio_arrival_gap` satırına `suppressed=`'dan sonra `tick_late_ms=` eklendi: boşluk penceresi [`read` dönüşü − `gap_ms`, `read` dönüşü] ile örtüşen tiklerin en büyük gecikmesi (henüz uyanmamış ama gecikmiş tik dahil). `-` = dedektör çalışmıyor ya da kapsam yok.
    - ≈ `gap_ms` → tablet süreci/CPU durmuş;
    - ~0 → veri gerçekten geç gelmiş (ağ yığını ya da Mac).
- **Varsayımlar:**
  - Uptime saati olarak `System.nanoTime()` kullanıldı (`CLOCK_MONOTONIC`, Android'de uptime ile aynı; T-117 `readNs` ile aynı saat). `SystemClock.uptimeNanos()` API 35'te geldiği için `minSdk 29`'da yok.
  - Dedektör kontrol bağlantısı varken çalışır: `OpenControl`/`PromoteCandidate`'de başlar, `CloseControl`'de ve motor kapanışında durur. Yeniden bağlanmada iş parçacığı yeniden kurulur ve istatistikler sıfırlanır. Durdurma, eski iş parçacığını en çok 100 ms bekler (normalde < 1 ms).
  - Geç tik, kaçırılan tikleri toplu çalıştırmaz: sonraki uyanma, bu uyanmadan 5 ms sonradır.
  - Maliyet: 200 uyanma/s × ~10–20 µs ≈ tek çekirdeğin %0,2–0,4'ü; tik yolunda ayırma yok. Saniyede bir sysfs okuması ve bir log satırı (ayırır, tik yolunun dışında).
- **Test edilmeyenler / cihazda doğrulanacaklar:**
  1. `adb logcat -s 'MB/diag:*'`: `stall_detector_start prio=-19` mu (yoksa -16 / 0)? `cpu_freq_files` > 0 mı?
  2. `stall_stats`: boşta `ticks` ~195–200, `tick_late_max_ms` birkaç ms, `stalls=0`, `suspend_ms=0.0`, `cpu_freq_khz` sayı mı (SELinux engelliyorsa `-`)?
  3. Apple Music çalarken küme anlarında: `ev=stall` satırı geliyor mu, `audio_arrival_gap` `tick_late_ms` değeri `gap_ms`'e yakın mı (tablet donmuş) yoksa ~0 mı (veri geç gelmiş)? `suspend_ms` > 0 ise derin uyku/askı.
  4. Regresyon: ses/görüntü normal, CPU/ısı değişimi yok (`top -H` içinde `mb-stall` ihmal edilebilir olmalı).
  5. Oturum kapanınca (`session_stop`) `stall_detector_stop` gelmeli ve `stall_stats` satırları durmalı.
- **Açık sorular:**
  - Huawei arka plana alınan uygulamayı dondurursa (`ev=stall` + `suspend_ms=0`) bu da görünür olur; ama uygulama ön plandayken de oluyorsa neden ayrı kart.
