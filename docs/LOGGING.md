# Runtime log kuralları

Loglar hem hata ayıklamanın hem de ajanların cihazdaki davranışı "görmesinin" tek yolu. Mac ve tabletteki loglar aynı oturum kimliğiyle eşleştirilebilmelidir.

## Satır formatı (her iki taraf)

```text
<mono_ms> <LEVEL> <component> sid=<session> gen=<n> ev=<event_name> key=value ...
```

- `mono_ms`: monoton saat (Mac: `ContinuousClock`/`mach_absolute_time`, Android: `SystemClock.elapsedRealtime`). Duvar saati ayrıca satır başına eklenebilir ama karşılaştırmalar monotonla yapılır.
- `LEVEL`: `E` hata, `W` uyarı, `I` bilgi, `D` debug (varsayılan kapalı).
- `component`: `capture`, `encoder`, `net`, `vdisplay`, `input`, `pen`, `kbd`, `decoder`, `render`, `session`.
- `ev`: snake_case olay adı, ör. `ev=connect_ok`, `ev=frame_drop reason=stale`.

## Nereye yazılır

| Taraf | Canlı | Dosya |
|---|---|---|
| Mac | `os.Logger` subsystem `dev.matebridge.host` | `~/Library/Logs/MateBridge/host.log` (döner, maks. 5×10 MB) |
| Android | `Log` tag `MB/<component>` (`adb logcat -s 'MB/*'`) | uygulama dizininde `logs/client.log` (döner), `adb` ile çekilir |

## Gizlilik (kesin kural)

- Tuş karakteri, metin, pano içeriği **asla** loglanmaz. Keycode yalnızca `D` seviyesinde.
- Ekran görüntüsü/kare içeriği loglanmaz.
- Loglar repoya commit'lenmez (`.gitignore`).

## Taşıma ve dinleyici olayları (Mac, `session`)

- `ev=listening control_port=… video_port=… service_class=… video_socket=bsd|nw notsent_lowat_kb=<n>|na control_socket=bsd|nw`: dinleyiciler hazır.
  - `video_socket` → `MATEBRIDGE_VIDEO_SOCKET` (T-091/T-092).
  - `control_socket` → `MATEBRIDGE_CONTROL_SOCKET` (T-111). İkisinin de varsayılanı `bsd` (çekirdek soketi); `nw` Network.framework geri dönüşü.
- `ev=bonjour_registered port=…`: `bsd` kontrol dinleyicisinin `_matebridge._tcp` kaydı yapıldı. Ad loglanmaz.
- `ev=bonjour_failed code=<dns_sd hata kodu> retry_s=<n>`: kayıt başarısız ya da sonradan koptu; 1…30 sn geri çekilmeyle yeniden denenir. Oturumlar etkilenmez.
- `ev=control_accept_paused errno=…` / `ev=video_accept_paused errno=…`: tanımlayıcı/tampon tükendi, kabul 1 sn duraklar.
- `ev=control_listener_socket_error error=…` / `ev=video_listener_socket_error error=…`: dinleme soketi açılamadı ya da bozuldu. Dinleyiciler yeniden başlatılır.
- `ev=connection_refused video=true|false reason=too_many_unauthenticated|socket_setup`: bağlantı reddedildi.
- `ev=send_backlog [reason=write_refused]`: kontrol bağlantısı yazılamıyor (eş okumuyor ya da bağlantı kapandı). Bağlantı kapatılır ve girdi bırakılır.

## Sayaçlar

Her 1 saniyede bir `ev=stats` satırı: fps, bitrate, kuyruk derinlikleri, düşürülen kare, girdi olay sayısı. Ekrandaki istatistik katmanı da aynı sayaçlardan beslenir.

## Ses gönderim zamanlaması (Mac, `audio`, T-116)

Yalnız ölçüm; davranışı değiştirmez. Değerler oturum kuyruğunda (`dev.matebridge.session`) toplanır.

- `ev=send writes=… queue_lag_ms_p50_max=a/b cap_to_write_ms_p50_max=a/b write_int_ms_max=… write_block_ms_max=… partial_writes=… pending_bytes_max=… gaps=…` (info): ses yazımı olan her ~1 sn'de bir; `AUDIO_CONFIG` geçince kalan pencere de yazılır.
  - `queue_lag_ms`: `sendAudio` çağrısından oturum kuyruğunda drain geçişinin başlamasına kadar (p50 / en büyük).
  - `cap_to_write_ms`: paketin `capture_time_us` değerinden mühürleme + yazım çağrısının dönüşüne kadar (p50 / en büyük).
  - `write_int_ms_max`: ardışık iki `AUDIO_FRAME` yazımı arasındaki en büyük aralık. `AUDIO_CONFIG` (akış sınırı) aralığı sıfırlar.
  - `write_block_ms_max`: tek bir mühürleme + yazım çağrısının en uzun süresi.
  - `partial_writes` / `pending_bytes_max`: yazımdan sonra kullanıcı alanında bekleyen bayt kalan yazım sayısı ve en büyük bekleyen bayt. `bsd` kontrol soketinde bu, çekirdeğin almadığı bayttır (EAGAIN ya da kısmi yazım). `nw`'de çekirdek görülemez; yazımdan önce Network.framework'ün henüz işlemediği bayt yazılır.
  - `gaps`: aralığı 20 ms'yi aşan yazım sayısı (hız sınırına takılanlar dahil).
- `ev=send_gap int_ms=… queue_lag_ms=… pending_bytes=… last_rx=<tür>|na last_rx_ago_ms=… slow_rx=<tür>|na slow_rx_ms=…` (debug): bir ses yazımı öncekinden 20 ms'den sonra geldiğinde, saniyede en çok 5 satır.
  - `last_rx`: oturum kuyruğunda bu yazımdan önce işlenen son kontrol mesajının türü (`MessageType` adı, ör. `pen`, `key`). `last_rx_ago_ms` bu mesajın işlenmesinin ne kadar önce bittiğini verir.
  - `slow_rx`: önceki ses yazımından bu yana en uzun işlenen kontrol mesajının türü. `slow_rx_ms` işleme süresidir (CGEvent dahil).
  - Yalnız mesaj türü yazılır; tuş, metin ve pano içeriği asla yazılmaz.

## Ses varış zamanlaması (tablet, `MB/audio`, T-117)

Yalnız ölçüm; davranışı değiştirmez. Yalnız güncel kontrol bağlantısının paketleri ölçülür; yeni bağlantıda ve her `AUDIO_CONFIG`'de sıfırlanır.

- Ses `ev=stats` satırının sonuna eklenen alanlar (1 ondalık ms; veri yoksa `-`):
  - `arr_int_ms_p50`, `arr_int_ms_max`: ardışık AUDIO_FRAME'lerin `read()` dönüş anları arasındaki aralık (aynı okumadan çıkanlar 0). 1 s'den uzun aralık akış duraklaması sayılır, dahil edilmez.
  - `owd_ms_p50`, `owd_ms_p95`, `owd_ms_max`: tek yön gecikme = varış (`read()` dönüşü, şifre çözmeden önce) + ClockSync farkı − `capture_time_us` − paket süresi (paketin son karesinin yaşı). Negatif olabilir (fark hatası ±RTT/2).
  - `per_read_max`: bir `read()`'den çıkan en çok ses paketi.
  - `decrypt_ms_max`: paketi üreten `RecordDecoder.next()` çağrısı (şifre çözme + çözümleme).
  - `arr_gaps`: penceredeki > 20 ms aralık sayısı; `arr_n`: penceredeki paket sayısı.
- `D audio ev=audio_arrival_gap gap_ms= owd_ms= per_read= decrypt_ms= since_video_ms= suppressed= gc_count= gc_time_ms= gc_blocking_count= gc_blocking_time_ms=` (debug, saniyede en çok 5): ardışık iki paket arası > 20 ms.
  - `suppressed`: önceki satırdan beri hız sınırına takılan boşluk sayısı.
  - `since_video_ms`: boşluğu bitiren ses okumasının dönüşü − video okuyucunun son veri dolu `read()` dönüşü (negatif: video arada geldi; `-`: video okuması yok). Video fps=0 iken anlamsız büyür.
  - GC alanları ART kümülatif sayaçlarıdır (`Debug.getRuntimeStat`); iki satır arası fark okunur.
  - Okuma: owd normal + aralık büyük → host geç yazmış (T-116 `ev=send_gap` ile karşılaştır); owd büyük → aktarım; video akarken `since_video_ms` ≈ `gap_ms` → tablet okuması duraklamış.

## Ses güvenlik payı (tablet, `MB/audio`, T-118)

- `ev=safety_start api=aaudio|track stored=<ms|-> used=<ms> source=…`: çıkış açılırken bir kez yazılır. `stored`: saklanan değer. `used`: başlangıç payı; saklanan değer en çok 30 ms (`SafetyMemory.REMEMBER_MAX_MS`) olarak okunur, AAudio'da taban 20 ms.
- Ses `ev=stats` satırına eklenen alanlar:
  - `refill_trims`: alt taşmadan sonraki toplu varışta, çalma başlamadan eşiğin üstündeki fazla atıldığı başlangıç sayısı;
  - `refill_trim_ms`: atılan toplam süre.

## Ses yakalama yeniden denemesi (Mac, `audio`, T-119)

- `ev=audio_retry reason=tap_create|aggregate_create attempt=N delay_ms=… status=… stream_id=…` (info): tap ya da aggregate oluşturulamadı (hata kodu, ya da `noErr` ama nesne yok). En çok 4 deneme yapılır: 100, 250, 500, 1000 ms; her deneme yeni bir `stream_id` alır. Hepsi başarısız olursa bugünkü `audio_unavailable` satırı yazılır.

## Süreç donma dedektörü (tablet, `MB/diag`, T-120)

Yalnız ölçüm. `mb-stall` iş parçacığı oturum boyunca 5 ms'de bir uyanır.

- `ev=stall_detector_start prio= period_ms=5 cpu_freq_files=`: `prio` iş parçacığının elde ettiği öncelik (-19 URGENT_AUDIO, -16 AUDIO). `cpu_freq_files` okunabilen `scaling_cur_freq` dosya sayısı. Kapanışta `ev=stall_detector_stop`.
- `ev=stall_stats ticks= tick_late_max_ms= stalls= suspend_ms= cpu_freq_khz=` (saniyede bir):
  - `ticks`: penceredeki tik sayısı (beklenen ~200);
  - `tick_late_max_ms`: beklenen uyanmaya göre en büyük gecikme;
  - `stalls`: 30 ms'den geç kalan tik sayısı;
  - `suspend_ms`: `elapsedRealtime − uptime` artışı (cihazın askıda geçirdiği süre);
  - `cpu_freq_khz`: çekirdeklerin en yüksek `scaling_cur_freq` değeri; okunamazsa `-`.
- `ev=stall dur_ms= suspend_ms= ctl_idle_ms= video_idle_ms= suppressed=`: tik 50 ms'den geç kaldığında, saniyede en çok 5 satır.
  - `*_idle_ms`: okuyucunun son veri dolu `read()` dönüşünden bu yana geçen süre.
  - `suppressed`: hız sınırına takılıp yazılmayan donma sayısı.
- Ses `audio_arrival_gap` satırına `tick_late_ms=` eklendi: boşluk penceresindeki tiklerin en büyük gecikmesi.
  - `gap_ms`'e yakınsa tablet süreci donmuştur;
  - ~0 ise veri gerçekten geç gelmiştir (ağ yığını ya da Mac).
