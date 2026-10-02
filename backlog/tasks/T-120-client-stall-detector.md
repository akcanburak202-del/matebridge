---
id: T-120
title: Tablet — süreç donma dedektörü (yüksek öncelikli tik iş parçacığı); ses/görüntü varış boşluklarının tabletten mi geldiğini ayır
status: todo
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

_(Ajan kodlamadan önce doldurur.)_

## Handoff

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
