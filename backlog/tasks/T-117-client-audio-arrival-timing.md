---
id: T-117
title: Tablet — ses paketi varış ölçümü (varış aralığı, tek yön gecikme, okuma başına paket) ve boşlukta video okuyucuyla karşılaştırma
status: in-progress
phase: 5
owner: android-client-dev
depends_on: []
decisions: [0011]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/session/SessionController.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/audio/
  - client-android/app/src/main/kotlin/dev/matebridge/client/stream/
  - client-android/app/src/test/
  - backlog/tasks/T-117-client-audio-arrival-timing.md
---

## Amaç

NOTES 2026-10-02 ~09:20: ses paketleri oturum başına ~11 kez 25–40 ms geç varıyor. Güvenlik payı her doğrulanmış alt taşmada +5 ms büyüyor ve ses gecikmesi 70–113 ms'ye çıkıyor.

Şu an tablette paket başına varış ölçümü yok. Tek ipucu saniyelik `level_ms_floor` düşüşleri ve bunlar video fps=0 iken de görülüyor.

Bu kart yalnız ölçüm ekler; düzeltme yok. T-116 (host gönderim ölçümü) ile birlikte gecikmenin yerini ayırır.

## Kapsam dışı

- `DriftController` / `SafetyMemory` davranışı (güvenlik payının küçülmesi, yeniden dolum aşımı): ayrı kart, bu ölçümden sonra.
- Protokol değişikliği.
- Host tarafı (T-116).

## Kabul kriterleri

- [ ] Kontrol okuyucu (`readRecords`) her AUDIO_FRAME için şunları alır:
  - varış anı: okuma döndükten sonra, şifre çözmeden önce ve sonra;
  - tek yön gecikme: varış + `ClockSync` farkı − `capture_time_us` − paket süresi;
  - bu `read()` çağrısından çıkan ses paketi sayısı (yığılma).
- [ ] Saniyelik ses `ev=stats` satırına eklenir:
  - `arr_int_ms_p50/max`
  - `owd_ms_p50/p95/max`
  - `per_read_max`
  - `decrypt_ms_max`

  Satır biçimi `docs/LOGGING.md` ile uyumlu. LOGGING.md bu kartın `files:` listesinde değil; yeni alanları *Handoff*'a yaz, orkestratör ekler.
- [ ] Ardışık iki ses paketi arasında > 20 ms varış boşluğu olursa bir `debug` satırı yazılır: boşluk, tek yön gecikme, okuma başına paket, video okuyucunun son varışından bu yana geçen süre, son GC'den beri süre (erişilebiliyorsa). Hız sınırlı (saniyede en çok 5).

  Bu satır host yazımı geç mi (owd normal, aralık büyük), aktarım mı (owd büyük), yoksa tablet okuması mı (iki okuyucu birlikte durmuş) ayrımını görünür kılar.
- [ ] Ölçüm okuma döngüsüne ayırma (allocation) eklemez. Hesap saf Kotlin, birim testli.
- [ ] `./scripts/check.sh` geçiyor. Cihaz ölçümü orkestratörde.

## Plan

1. **Saf sınıf `audio/AudioArrival.kt` → `AudioArrivalMeter`** (JVM birim testli, ayırmasız kayıt yolu):
   - Önceden ayrılmış `LongArray` pencereleri (aralık µs, owd µs; kapasite 512, taşarsa yüzdelik örneği atlanır ama max kesin kalır).
   - `onPacket(readNs, decodeStartNs, decodedNs, captureHostUs, frameCount)`: varış aralığı (aynı okumadaki paketler 0), tek yön gecikme = varış + saat farkı − `capture_time_us` − paket süresi (48 kHz), şifre çözme süresi (`decoder.next()` öncesi/sonrası). > 20 ms aralık bekleyen boşluk olarak işaretlenir. 1 s'den uzun aralık akış duraklaması sayılır, istatistiğe girmez.
   - `endRead(audioCount)`: okuma başına paket max; bekleyen boşluk varsa hız sınırına (saniyede en çok 5) bakar, `true` = debug satırı yazılsın; ayrıntı yeniden kullanılan `Gap` nesnesinde.
   - `setOffset(us?)` (volatile), `reset()` (yeni bağlantı / AUDIO_CONFIG), `takeWindow(out)`: p50/p95/max sıralaması önceden ayrılmış çizik dizide, pencereyi sıfırlar. `Window.logFields()` alan dizgisini üretir (`-` = veri yok).
   - Okuyucu ve yazıcı iş parçacığı arasında `synchronized` (çekişmesiz monitor ayırmaz).
2. **`SessionController`**: paylaşılan örnek `AudioArrivalMeter.shared`. Kontrol okuyucu `read()` dönüşünde zaman alır, her mesaj için `next()` öncesi/sonrası; `AudioFrame` → `onPacket`, `AudioConfig` → `reset`; iç döngü sonunda `endRead`. Özel `ClockSync` PONG'larla beslenir (MainActivity'deki gibi oturum başında sıfırlanır) ve farkı meter'a yazar. Video okuyucu son varışını `@Volatile` alana yazar. Boşluk satırı `Log.d` + `MbLog.format(..., 'D', "audio", ...)` (`ev=audio_arrival_gap`): `gap_ms owd_ms per_read since_video_ms gc_count gc_time_ms gc_blocking_count` (`Debug.getRuntimeStat`; son GC zamanı API'de yok, kümülatif sayaç verilir).
3. **`AudioPlayout.logStats`**: `AudioArrivalMeter.shared.takeWindow(...)` alanlarını ses `ev=stats` satırının sonuna ekler: `arr_int_ms_p50 arr_int_ms_max owd_ms_p50 owd_ms_p95 owd_ms_max per_read_max decrypt_ms_max arr_gaps arr_n`.
4. Testler: `client-android/app/src/test/kotlin/dev/matebridge/client/audio/AudioArrivalMeterTest.kt`.

## Handoff

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
