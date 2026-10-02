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
