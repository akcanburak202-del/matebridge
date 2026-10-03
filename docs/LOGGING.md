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

## Build kimliği (her iki taraf, T-145/T-146)

Her süreç başlangıcında tam olarak bir satır. Hangi build'in çalıştığını log'dan okumak için kullanılır.

- Mac (`session`, `host.log`'un ilk satırı, `listening`'den önce): `ev=app_start version=<CFBundleShortVersionString> build=<YYYYMMDDhhmmss> sha=<kısa SHA>[-dirty] os=<macOS sürüm metni>`.
- Tablet (`MB/session`): `ev=app_start version=<versionName> sha=<kısa SHA>[-dirty] built=<UTC, dakika> sdk=<API> os_build=<Build.DISPLAY>`. Süreç başına bir kez; aktivite yeniden yaratılınca tekrarlanmaz.
- Değer içindeki boşluk (Mac'te `=` de) `_` olur, böylece her alan tek `key=value` kalır; ör. `os=Version_27.0.1_(Build_26A434)`.
- Bilinmeyen değer `unknown` (`swift run`, git olmadan derleme). Seri numarası, cihaz kimliği ya da ad yazılmaz.
- Tablette `versionCode` commit sayısıdır; daha az commit'li bir dalın APK'sı `adb install -r -d` ister (`scripts/install-apk.sh` bunu yapar). Eşleşme anahtarları silineceği için uygulama asla kaldırılmaz.

## Taşıma ve dinleyici olayları (Mac, `session`)

- `ev=listening control_port=… video_port=… service_class=signaling|video|off [video_class=… control_class=…] video_socket=bsd|nw notsent_lowat_kb=<n>|na control_socket=bsd|nw tcp_log=auto|on|off`: dinleyiciler hazır.
  - `service_class` → `MATEBRIDGE_SERVICE_CLASS` (T-088). Varsayılan T-124'ten beri `signaling`: `video_class=interactiveVideo control_class=interactiveVoice` (Wi-Fi'de video AC_VI, kontrol/ses AC_VO). `off` sınıfları ayarlamaz (T-088 öncesi davranış) ve yalnızca `service_class=off` yazar. Tanınmayan değer varsayılana düşer. USB'de (adb tüneli) etkisizdir.
  - `video_socket` → `MATEBRIDGE_VIDEO_SOCKET` (T-091/T-092).
  - `control_socket` → `MATEBRIDGE_CONTROL_SOCKET` (T-111). İkisinin de varsayılanı `bsd` (çekirdek soketi); `nw` Network.framework geri dönüşü.
  - `tcp_log` → `MATEBRIDGE_TCP_LOG` (T-126), bkz. aşağıda "Kontrol ve video soketlerinin TCP durumu".
- `ev=bonjour_registered port=…`: `bsd` kontrol dinleyicisinin `_matebridge._tcp` kaydı yapıldı. Ad loglanmaz.
- `ev=bonjour_failed code=<dns_sd hata kodu> retry_s=<n>`: kayıt başarısız ya da sonradan koptu; 1…30 sn geri çekilmeyle yeniden denenir. Oturumlar etkilenmez.
- `ev=control_accept_paused errno=…` / `ev=video_accept_paused errno=…`: tanımlayıcı/tampon tükendi, kabul 1 sn duraklar.
- `ev=control_listener_socket_error error=…` / `ev=video_listener_socket_error error=…`: dinleme soketi açılamadı ya da bozuldu. Dinleyiciler yeniden başlatılır.
- `ev=connection_refused video=true|false reason=too_many_unauthenticated|socket_setup`: bağlantı reddedildi.
- `ev=send_backlog [reason=write_refused]`: kontrol bağlantısı yazılamıyor (eş okumuyor ya da bağlantı kapandı). Bağlantı kapatılır ve girdi bırakılır.

## Eşleşmiş bağlantıda kanıt (Mac, `session`, T-041/T-152)

- `ev=paired_proving conn=…`: PAIRED bağlantı ACCEPTED aldı, oturum ilk doğrulanmış kaydı bekliyor (devralma olmadan). Beklenen sıra: `handshake mode=paired` → `paired_proving` → `session_started`.
- `ev=takeover_proving conn=…`: aynı, ama aynı cihazın canlı bir oturumu devralınacak.
- `ev=proof_timeout conn=…` (W): 5 sn içinde doğrulanmış kayıt gelmedi, bağlantı BYE'sız kapatıldı. T-152'den beri devralma olmayan bağlantılarda da çıkar; sık görülüyorsa tablet yanlış anahtar kullanıyor olabilir (T-156).

## Onay penceresi (Mac, `session`, T-043/T-155)

- `ev=approval_pending replaced=none|same|other`: yeni bir eşleşme isteği Mac'te onay penceresi açtı. `same`: açık bir öksüz pencerenin yerini aynı cihazın yeni isteği aldı (kod değişti). `other`: farklı bir cihaz aldı; pencerede kırmızı "FARKLI bir cihaz" uyarısı ve cihaz parmak izi görünür. `other` bayrağı o pencere için kullanıcı karar verene ya da süre dolana kadar kalır. Ad, kod ve parmak izi loglanmaz.

## Kontrol ve video soketlerinin TCP durumu (Mac, `net`, T-126)

Yalnız ölçüm; davranışı değiştirmez. Etkin oturumun kontrol bağlantısı (ses buradan gider) ve bağlı video bağlantısı oturum kuyruğunda saniyede bir okunur. Her biri için soket başına saniyede bir `getsockopt(TCP_CONNECTION_INFO)` yapılır.

- Ne zaman açık: `MATEBRIDGE_TCP_LOG`.
  - Ayarsız (`auto`): Wi-Fi oturumunda açık. USB'de yalnız `MATEBRIDGE_SENDQ_LOG=1` ya da `MATEBRIDGE_LAT_TRACE=1` ile açılır, çünkü adb loopback'te RTT ve yeniden gönderim bilgi taşımaz.
  - `1`: her oturumda açık.
  - `0`: kapalı.
- `I net ev=tcp conn=control|video conn_id=<n> retx_pkts_delta= rxmit_bytes_delta= ooo_bytes_delta= tx_pkts_delta= srtt_ms= rttvar_ms= rttcur_ms= rto_ms= snd_cwnd= snd_wnd= ssthresh= sndbuf_bytes= unacked_bytes= notsent_bytes= user_pending_bytes=<n>|na loss_recovery=0|1 transport=usb|wifi`: her soket için saniyede bir satır, önce kontrol.
  - `*_delta`: önceki satırdan bu yana artış. Bağlantının ilk satırı bağlantı başından sayar.
    - `retx_pkts`, `rxmit_bytes`: yeniden gönderilen paket ve bayt.
    - `ooo_bytes`: tabletten sıra dışı gelen bayt (Mac'e doğru yön). API paket sayısı vermez.
    - `tx_pkts`: gönderilen paket.
  - `srtt_ms`, `rttvar_ms`, `rttcur_ms`, `rto_ms`: yumuşatılmış RTT, sapması, son RTT ve yeniden gönderim zaman aşımı (ms).
  - `snd_cwnd`, `snd_wnd`, `ssthresh`: tıkanıklık penceresi, tabletin alma penceresi ve yavaş başlangıç eşiği (bayt).
  - `sndbuf_bytes`: çekirdek gönderim tamponu (`tcpi_snd_sbbytes`), onaylanmamış + gönderilmemiş bayt.
  - `unacked_bytes`, `notsent_bytes`: **tahmin**, çünkü herkese açık API bu ikisini ayırmaz.
    - `unacked_bytes = min(sndbuf_bytes, snd_cwnd, snd_wnd)`: Nagle kapalı, pencere izin veriyorsa bayt yoldadır.
    - `notsent_bytes = sndbuf_bytes − unacked_bytes`.
  - `user_pending_bytes`: `bsd` soketinde çekirdeğin henüz almadığı, kullanıcı alanında bekleyen bayt. `nw`'de `na`.
  - `loss_recovery=1`: okuma anında TCP kayıp kurtarmadaydı (`TCPCI_FLAG_LOSSRECOVERY`).
- `D net ev=tcp_snap … trigger=send_gap`: ses `ev=send_gap` satırının hemen ardından kontrol soketinin anlık durumu. Alanlar `ev=tcp` ile aynıdır. `*_delta` son `ev=tcp` satırından bu yanadır ve tabanı ilerletmez. `send_gap` saniyede en çok 5 kez yazıldığı için ek okuma da en çok 5'tir.
  - Retx olan bir saniye için ayrı satır yazılmaz. O saniyenin `ev=tcp` satırı zaten okuma anındaki durumu taşır.
- `W net ev=tcp_unavailable conn=control|video conn_id=<n> reason=no_endpoints|unavailable`: soket okunamadı (ör. `nw` bağlantısında çekirdek tanımlayıcısı yok). Bağlantı başına bir kez yazılır.
- Video `ev=sendq` satırı (T-088) değişmedi. Kare başına ayrı bir örnekleyiciyle çalışır, iki satır birbirini etkilemez.
- Okuma: ses boşluğu sırasında `retx_pkts_delta` > 0 ya da `rto_ms` büyükse TCP yeniden gönderimi sorumludur. `notsent_bytes` / `user_pending_bytes` büyükse gönderim kuyruğu sorumludur. İkisi de temizse ve `srtt_ms` sıçramışsa hava kanalında (AP ya da tablet) kuyruklanma olasıdır.

## Sayaçlar

`ev=stats` satırı: fps, bitrate, kuyruk derinlikleri, düşürülen kare, girdi olay sayısı. Ekrandaki istatistik katmanı da aynı sayaçlardan beslenir.

İstemci video satırları (T-141): `MB/decoder ev=stats` ile `MB/render ev=stats` ve `ev=present` varsayılanda **10 s** pencereyi özetler. Toplamlar ve yüzdelikler pencere üzerinden kesindir, `interval_ms` gerçek pencere uzunluğudur. `--ez stats_1s true` açılış parametresi 1 s pencereye döndürür.
- Kare gelmeyen pencere yazılmaz. Akış biterken ya da yeniden yapılandırılırken yarım pencere yazılır.
- Açılışta `render ev=stats_log window_ms=10000|1000`.
- Vsync döngüsü ≥ 1 s uyuduğunda `render ev=idle state=on since_frame_ms=<n>`, uyanınca `state=off idle_ms=<n>`.
- Host'a giden STATS mesajı ve katman 1 s'de bir kalır. Diğer saniyelik satırlar (`session ev=net`, `audio ev=stats`, `diag ev=stall_stats`, `render ev=gl_stats`) değişmedi.

## Keyframe isteği birleştirme (Mac, `net`, T-122)

İstemcinin `KEYFRAME_REQUEST`'i yolda ya da yeni yazılmış bir IDR varsa yeni IDR zorlamaz (`KeyframeRequestCoalescer`).

- `ev=keyframe_request reason=<n> action=forced|coalesced|config_resent idr_forced=0|1 since_idr_ms=<n>|-` (info): her istek için bir satır.
  - `reason`: 0 STARTUP, 1 DECODE_ERROR, 2 FRAMES_DROPPED.
  - `forced`: yeni IDR zorlandı.
  - `coalesced`: zorlanmadı, yalnız sayıldı. Sebep: zorlanmış bir IDR henüz yazılmadı (en çok 1 sn) ya da son IDR yazımı 250 ms'den yeni.
  - `config_resent`: STARTUP / DECODE_ERROR. `CODEC_CONFIG` yeniden kuyruğa kondu. `idr_forced=0` ise zorlanmış IDR hâlâ kodlayıcıdaydı ve config'in arkasından gelir. Önceden yazılmış bir IDR yeniden kurulan çözücüye yaramaz, o yüzden yeni IDR zorlanır.
  - `since_idr_ms`: son keyframe yazımının (çekirdeğe verilmesinin) bitişinden bu yana; hiç yazılmadıysa `-`.
  - Eski ayrı `ev=codec_config_resent` satırı yerine `action=config_resent`.
- `net ev=stats` satırının sonuna: `idr=<n> idr_bytes_max=<n>`: önceki stats satırından bu yana yazımı biten keyframe sayısı ve en büyüğünün `VIDEO_FRAME` yük boyutu (bayt).

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

Yalnız ölçüm, T-142'den beri isteğe bağlı: yalnız `--ez stall_diag true` açılış parametresiyle çalışır. Açılışta her zaman bir kez `diag ev=stall_diag enabled=0|1`. Açıkken `mb-stall` iş parçacığı oturum boyunca 5 ms'de bir uyanır. Kapalıyken `stall_*` satırı yazılmaz, ses boşluğu satırında `tick_late_ms=-`.

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

## Video kuyruğu ve keyframe istekleri (tablet, `MB/decoder`, T-121)

- `ev=stats` satırının sonuna eklenen alanlar (pencere başına sıfırlanır):
  - `kf_req`: gönderilen istek;
  - `kf_held`: 500 ms sınırına takılıp bekletilen istek;
  - `overflows`: kuyruk taşması;
  - `max_pending`: bekleyen kare tepe değeri;
  - `limit`: kuyruk sınırı (fps'e göre ~64 ms).
- `W decoder ev=queue_overflow pending= limit= in_codec= decode_last_us= since_kf= gaps_us= req=sent|held since_req_ms=`: her taşmada yazılır. `gaps_us` son varış aralıklarıdır.
  - Küçük aralıklar + düşük `in_codec`: ağ yığılması.
  - Yüksek `in_codec` / uzun `decode_last_us`: çözücü yetişmiyor.
- `I decoder ev=kf_request reason= src=overflow|deferred|retry|reset|error`: gönderilen her KEYFRAME_REQUEST için.

## Ses güvenlik payı bağlantı türüne göre (tablet, `MB/audio`, T-123)

- `ev=safety_start` satırına `transport=usb|wifi` eklendi. Pay `api/transport` başına saklanır (`aaudio/usb`, `aaudio/wifi`, `track/usb`, `track/wifi`). Eski tek anahtarlı kayıt USB değeri sayılır.
- Wi-Fi'de taban ve başlangıç 40 ms, en çok 50 ms hatırlanır, oturum içinde en çok 70 ms. USB'de bunlar 20 (Uyumlu'da 5), 30 ve 40 ms.
- `ev=safety_transport from= to= used= stored= live=0|1`: akış öncekinden farklı bir bağlantı türünde açıldığında. `live=0` akışın yeniden açıldığını gösterir; bugünkü geçiş yolu budur.

## Toplu geç varışta ileri atlama (tablet, `MB/audio`, T-125)

- Ses `ev=stats` satırına `skip_trims=` ve `skip_trim_ms=` eklendi: çalarken seviyedeki fazlalık 3 ms'lik çapraz geçişle kaç kez atıldı, toplam kaç ms atıldı.
- İki durumda atılır:
  - alt taşmadan sonraki 2 s'lik pencerede, seviye tabanı hedefin 20 ms'den fazla üstündeyse (pencere başına en çok bir kez);
  - pencere dışında, taban hedefin 60 ms'den fazla üstünde ~3 s kalırsa.
- Atlama içeren saniyenin A/V örneği `onAvOffset`'e verilmez.

## Video sağlığı ve input kapısı (tablet, `MB/decoder`, T-159, karar 0019)

- `ev=video_health state=idle|starting|healthy|fault cause=-|give_up|no_output|not_running|stuck from=<önceki> vgen=N` (I; fault'ta W). Input yalnız `healthy`'de açık; her `starting` ve `fault` input'u kapatır (`RELEASE_ALL(USER)`). `vgen` decoder kuşağıdır (`gen=` zaten oturum kuşağı).
- `ev=video_recover step=restart|reconnect|manual|retry|done n=N vgen=N` (W; `done` I): kurtarma adımları, +1 sn ve +3 sn decoder yeniden başlatma, +6 sn oturumu yeniden kurma, +15 sn "Yeniden dene".
- `ev=decoder_fault mode=create|configure|dequeue|silent armed_s=N` (W): yalnız debug hata enjeksiyonu (`--es decoder_fault …`), görüntü N sn `healthy` kaldıktan sonra bir kez.

## Encoder gönderim sırası (Mac, `encoder`, T-162)

- Encoder'a her kare tek bir seri sahip kuyruğundan gider; rezervasyon sırası = VideoToolbox çağrı sırası, `stop` sonrası encode yok.
- `ev=slot_double_release` (W): aynı rezervasyon ikinci kez bırakıldı; sayaç değişmez. Normal kullanımda hiç görülmemeli; görülürse hata.

## Bekletilen sanal ekran (Mac, `net`, T-165)

Oturum bitince yakalama (SCK) ve encoder (VT) hemen durur; yalnız sanal ekran bekletme süresi boyunca tutulur. Süre `MATEBRIDGE_DISPLAY_KEEP_S` (10…86400 sn, aksi halde 10) ve duvar saatiyle sayılır (sürekli saat, Mac uykusunda da ilerler).

- `ev=display_parked keep_s=<n> refresh_hz=<hz>`: oturum bitti, ekran bekletiliyor (eski `display_grace_started`'ın yerine). Bekleme sırasında `cadence`/`latency` satırı çıkmaz.
- `ev=display_park_skipped reason=no_display`: bekletilecek ekran yoktu (işlem hattı tam o anda düşmüştü).
- `ev=display_unparked parked_ms=<n> refresh_hz=<hz>`: aynı tablet döndü, bekletilen ekranda yeni yakalama ve encoder kurulur. Ekran korunursa ardından `ev=pipeline_started display=reused width=… height=… encoded=…` gelir, `display_created` gelmez.
- `ev=display_recreate reason=refresh_change refresh_hz=<eski>-><yeni>` / `reason=offline`: yenileme hızı değişti ya da ekran bekletilirken çevrimdışı oldu (`CGDisplayIsOnline`). Eski ekran bırakılır, 0,7 sn sonra yenisi kurulur (`display_created`). Canlı mod değişiminde de (`stream_reconfigure`) aynı satırlar çıkar.
- `ev=display_teardown reason=keep_expired|device_changed|size_changed|shutdown`: ekran (bekletilen ya da çalışan) kaldırıldı. `keep_expired` süre doldu, `device_changed` başka tablet, `size_changed` başka ekran boyutu, `shutdown` uygulama kapanıyor.
- `ev=display_created width=… height=… encoded=…`: yeni bir sanal ekran kuruldu. Ekran korunarak yeniden kurulan işlem hattı (mod değişimi, bekletmeden dönüş) artık `pipeline_started display=reused` yazar.

## Tablette eşleşme güveni (tablet, `MB/session`, T-150/T-151, karar 0018)

Hiçbir alanda eşleşme kodu, anahtar, token, `host_id` ya da Mac adı yazılmaz. `pair_key_stored` kaldırıldı.

- Bekleyen kayıt: `pair_pending_stored re_pair=0|1`, `pair_pending_expired kind=pending|marker`, `pair_pending_drop_failed`, `pair_marker_clear_failed`, `pair_key_store_failed`.
- Onay: `pair_trust_confirmed where=live|stored host_accepted=0|1`, `pair_trust_confirm_failed`, `pair_trust_cancelled reason=user|timeout|stale`, `pair_trust_event_stale kind=confirm|cancel` (ekranda gösterilmeyen bir isteme dokunuldu, yok sayıldı), `pair_prompt_visible visible=0|1`, `pair_stored_prompt confirmed=0|1`, `pair_paired_with_pending`, `pair_rejected confirmed=0|1`.
- Kullanıcıyla başlama: `pairing_needs_user re_pair=0|1` (kullanıcının başlatmadığı bağlantıya PAIRING cevabı geldi; hiçbir şey saklanmadı), `pair_auto_skip origin=` (eşleşme isteyen adres kendiliğinden bağlanmada atlandı), `pair_cancel_latched` (İptal/zaman aşımından sonra otomatik başlatma engellendi).
- Unut: `pair_forget live=0|1`, `pair_forget_none`, `pair_forget_failed live=0|1`, arayüzde `pair_ui_forget_failed`.
- Arayüz: `pair_ui action=<eylem>` (yalnız eylem adı, değer yok).
- Alanlar: `session_start` ve `connect_start`'ta `user=0|1`; `transport`'ta `origin=`; `transport_pick reason=usb_asked`. `secured` artık PAIRED bağlantılarda da yazılır.
