# MateBridge protokolü — v1

**Durum:** v1 (2026-09-30): v0'a (T-007) oturum şifrelemesi eklendi (§9, karar 0010). `protocol_version = 1`. v0 istemci/host ile bağlantı kurulmaz (`VERSION_MISMATCH`). Değişiklik bu dosyada ve fixture'larda aynı commit'te yapılır. **Sahibi: orkestratör.**

Bu dosya Swift ve Kotlin tarafının tek ortak sözleşmesidir. Tasarım Aşama 0 ölçümlerine dayanır (`docs/NOTES.md`, 2026-09-29). Fixture'lar ile bu dosya çelişirse bu dosya geçerlidir.

## 1. Genel kurallar

- **Bayt sırası:** tüm sayılar **little-endian**. `f32` IEEE-754 binary32, sonlu olmalı (NaN/Inf protokol hatası).
- **Tipler:** `u8/u16/u32/u64` işaretsiz, `i16` işaretli (ikiye tümleyen), `str8` = `u8 uzunluk` + UTF-8 bayt (en çok 64 bayt, sonlandırıcı yok, boş olabilir), `bytes` = ham bayt.
- **Hizalama yok:** alanlar dolgu olmadan art arda gelir. `reserved` alanları gönderen **0** yazar, alıcı değerine **bakmaz**. Tanımsız bayrak bitleri de böyledir.
- **Yön:** C = istemci (tablet), H = host (Mac).
- **Zaman:** `*_time_us` alanları gönderenin **monoton** saatidir, mikrosaniye. İki tarafın saatleri doğrudan karşılaştırılmaz. Fark PING/PONG ile tahmin edilir (§6). Android API 31'de olay zamanları milisaniye çözünürlüklüdür (`eventTime × 1000`).
- **Normalize koordinat:** `x`, `y` (`u16`) tabletteki **video yüzeyi** üzerinde konumdur. `0` sol/üst kenar, `65535` sağ/alt kenar.
  - İstemci: `x = round(clamp(px / surface_width, 0, 1) × 65535)`. Video yüzeyi ekranın tamamı değilse (siyah bant) bant çıkarılır. Yüzey dışındaki noktalar kenara sıkıştırılır.
  - Host: `x_pt = origin_x + x / 65535 × width_pt`, sonra `[origin_x, origin_x + width_pt − 1/scale]` aralığına sıkıştırılır. `origin` ve `width_pt` sanal ekranın global koordinatlarıdır (`CGDisplayBounds`). Sanal ekran ana ekran olduğunda origin (0,0) olur, ama bu varsayılmaz.
- **Eğim ve basınç kodlaması:** `-1…1` aralığındaki değer `round(v × 32767)` ile `i16`'ya çevrilir. `-32768` gelirse `-32767` sayılır. `0…1` aralığındaki basınç `round(v × 65535)` ile `u16`'ya çevrilir.
- **Yuvarlama:** Bu belgedeki bütün `round()` işlemleri **sıfırdan uzağa yarım yuvarlama**dır (`round(2.5) = 3`, `round(−2.5) = −3`). Swift `.rounded()` varsayılanı budur. Kotlin/Java'da `Math.round` (pozitif sonsuza) ve `kotlin.math.round` (çifte) farklıdır, kullanılmaz: `sign(v) × floor(|v| + 0.5)`.

## 2. Bağlantılar ve çerçeveleme

İki ayrı TCP bağlantısı vardır. Büyük video kareleri girdi olaylarını bekletmesin diye ayrılırlar (head-of-line blocking).

| Bağlantı | Port | Seçenekler | İçerik |
|---|---|---|---|
| **Kontrol + girdi** | Bonjour ile bulunur (§3) | `TCP_NODELAY` her iki uçta | Oturum, girdi, heartbeat, istatistik. Sıralı ve kayıpsız. |
| **Video** | `HELLO_ACK.video_port` | `TCP_NODELAY` | Yalnızca `VIDEO_HELLO` (C→H) ve `VIDEO_FRAME` (H→C). |

USB kullanımında aynı bağlantılar `adb reverse` ile taşınır. Protokol değişmez.

**Çerçeve** (her iki bağlantıda aynı, 5 bayt başlık). Bu biçim yalnızca şifreleme başlamadan önceki mesajlar içindir (`HELLO`, ilk `HELLO_ACK`, `VIDEO_HELLO`); sonrasında her çerçeve şifreli kayıt biçimindedir (§9):

| Alan | Tip | Açıklama |
|---|---|---|
| `type` | u8 | Mesaj tipi (§4) |
| `length` | u32 | Yalnızca payload uzunluğu (başlık hariç) |
| payload | `length` bayt | Mesaja göre |

- **En büyük payload:** kontrol bağlantısında 65.536 bayt, video bağlantısında 16.777.216 bayt. Sınır, başlığın 5 baytı gelir gelmez denetlenir; alıcı payload'u tamponlamadan reddeder. Gönderen de sınırı aşan bir çerçeve **üretmez** (kodlayıcı hata verir).
- **Bilinmeyen tip:** alıcı payload'u atlar ve devam eder (ileri uyumluluk, fixture `unknown_type`).
- **Uzunluk:** bilinen bir tip beklenenden **uzun** payload ile gelirse fazlası yok sayılır (yeni alanlar yalnızca sona eklenir). Değişken uzunluklu alanların boyu her zaman kendi uzunluk alanından okunur (`str8` uzunluğu, `PEN.count`, `VIDEO_FRAME.frame_size`), "payload'un geri kalanı" olarak değil. **Kısa** gelirse protokol hatasıdır (fixture `invalid_key_short`).
- **Bilinmeyen enum değerleri:**
  - **Durumu belirleyen** alanlarda protokol hatasıdır: `HELLO_ACK.status`, `HELLO_ACK.key_mode`, `STREAM_CONFIG.codec`, `PEN.tool`, `KEY.action`, `POINTER_ABS.source`, `SCROLL.phase`, `PINCH.phase`, `PINCH.source`.
  - **Bilgi amaçlı** alanlarda kabul edilir ve "bilinmeyen" olarak işlenir: `BYE.reason`, `RELEASE_ALL.reason`, `KEYFRAME_REQUEST.reason` (davranış aynı: bırak / kapat / keyframe), `PEN_GESTURE.gesture` (yok sayılır), `STREAM_CONFIG` renk kodları (bilinmeyen kod: sRGB varsayılır).
  - Tanımsız `capabilities` ve bayrak bitleri yok sayılır.
- **Protokol hatası:**
  - Kontrol bağlantısında: alıcı `BYE(PROTOCOL_ERROR)` gönderir, **iki bağlantıyı da** kapatır.
  - Video bağlantısında: alıcı **yalnızca video bağlantısını** kapatır, `BYE` göndermez. Host'ta hata loglanır. İstemci video bağlantısını yeniden açabilir (§3.5).

## 3. Oturum akışı

1. **Keşif:** Host Bonjour ile `_matebridge._tcp` hizmetini yayınlar (TXT: `v=1`). İstemci Android `NsdManager` ile bulur, ya da IP/port elle girilir.
   - **Varsayılan portlar:** host önce **kontrol 47001**, **video 47002** portlarını dener; doluysa sistemin verdiği portları kullanır (Bonjour ve `HELLO_ACK.video_port` her zaman gerçek portu bildirir). USB modunda (`adb reverse tcp:47001 tcp:47001` ve `tcp:47002 tcp:47002`) istemci `127.0.0.1:47001`'e bağlanır; video bağlantısı da `127.0.0.1:<video_port>` adresine gider.
2. **HELLO:** İstemci kontrol bağlantısını açar ve ilk mesaj olarak `HELLO` gönderir. Host ilk 5 sn içinde `HELLO` almazsa bağlantıyı kapatır.
3. **HELLO_ACK:**
   - `protocol_version` farklıysa `VERSION_MISMATCH`, bağlantı kapanır. Host sürümü, HELLO'nun geri kalanını okumadan **önce** denetler (eski sürümün HELLO'su kısa olabilir); `VERSION_MISMATCH` cevabı şifresizdir ve `key_mode = NONE` taşır.
   - **Tek oturum:** host aynı anda tek oturum tutar.
     - Başka bir `device_id` ile aktif oturum varsa `BUSY` gönderilir ve bağlantı kapanır.
     - Aynı `device_id` ile yeni bir `HELLO` gelirse (yeniden bağlanma) eski oturum **devralınır**, ama yalnızca yeni bağlantı eşleşme anahtarına sahip olduğunu kanıtladıktan sonra (`device_id` şifresiz gider; ağdaki biri onunla oturumu düşüremesin): host `HELLO_ACK(ACCEPTED, PAIRED)` gönderir ve yeni bağlantıyı **kanıt bekliyor** durumuna alır. Yeni bağlantıdan **ilk doğrulanmış şifreli kayıt** gelince (istemci ACCEPTED'dan hemen sonra bir PING gönderir) host eski oturumun girdi durumunu release-all ile bırakır, eski bağlantılara `BYE(SUPERSEDED)` gönderip kapatır ve yeni oturumu ancak bundan **sonra** etkinleştirir; o ilk kayıt da etkinleştirmeden sonra işlenir. 5 sn içinde kanıt gelmezse yeni bağlantı kapatılır, eski oturum etkilenmez. Yarı açık kalmış eski TCP bağlantısı böylece yeni oturumun girdisine karışamaz.
     - Aktif oturum varken aynı `device_id` için **PAIRING** gerekecekse (host anahtarı yok) devralma yapılmaz: `BUSY`.
   - `device_id` daha önce onaylanmışsa ve bu cihaz için eşleşme anahtarı varsa `ACCEPTED` (`key_mode = PAIRED`).
   - Yeni cihazsa (ya da eşleşme anahtarı yoksa) önce `PENDING_APPROVAL` (`key_mode = PAIRING`) ve Mac'te "MatePad bağlanmak istiyor → İzin ver" sorulur; onay penceresi ve tablet aynı **6 haneli eşleşme kodunu** gösterir (§9). Kabul edilirse ikinci bir `HELLO_ACK(ACCEPTED)` gelir (şifreli). Reddedilirse veya **60 sn** içinde cevap yoksa `HELLO_ACK(REJECTED)` gelir (şifreli) ve bağlantı kapanır.
   - İlk `HELLO_ACK`'ten (PENDING ya da ACCEPTED) hemen sonra iki yönde de şifreleme başlar (§9). Terminal cevaplar (REJECTED ilk cevapsa, VERSION_MISMATCH, BUSY) şifresizdir, `key_mode = NONE` taşır ve bağlantı kapanır.
4. **STREAM_CONFIG:** `ACCEPTED` sonrası host `STREAM_CONFIG` gönderir.
5. **Video bağlantısı:** İstemci video bağlantısını `video_port`'a açar. İlk mesaj olarak şifresiz `VIDEO_HELLO(session_id, config_id, video_nonce)` gönderir; sonrası bu bağlantının anahtarlarıyla şifrelidir (§9); `config_id` istemcinin uyguladığı son `STREAM_CONFIG`'dir. Host, `session_id` veya `config_id` güncel değilse video bağlantısını kapatır. İstemci VIDEO_HELLO'nun hemen ardından video bağlantısında şifreli bir `PING` gönderir; host bu kayıt doğrulanana kadar o bağlantıya kare göndermez ve varsa eski video bağlantısını **kapatmaz** (anahtarı olmayan biri geçerli `session_id` ile akışı kesemesin). Kanıt 5 sn içinde gelmezse yeni video bağlantısı kapatılır. Video bağlantısındaki PING'e PONG gönderilmez. `video_nonce` her bağlantıda yenidir; host aynı oturumda tekrar eden bir `video_nonce`'u reddeder (bağlantıyı kapatır; aynı anahtar ve nonce ile AES-GCM tekrarını önler).
6. **Video akışı:** Host `VIDEO_FRAME` akışına başlar: önce `CODEC_CONFIG`, sonra keyframe.
7. **Ayar değişikliği** (çözünürlük, codec, FPS): Host yeni `config_id` ile `STREAM_CONFIG` gönderir, sonra mevcut video bağlantısını kapatır. İstemci yeni ayarı uygulayıp yeni `config_id` ile video bağlantısını yeniden açar. Böylece bir video bağlantısındaki bütün kareler tek bir ayara aittir ve iki bağlantı arasındaki sıra sorunu oluşmaz.

**Onay öncesi:** `ACCEPTED` gelmeden istemci girdi mesajı **göndermez**. Gelirse host yok sayar ve hiçbir olay enjekte edilmez. `PING/PONG`, `HELLO` alındıktan sonra her durumda (onay beklerken de) geçerlidir ve cevaplanır.

Onaylanmamış cihaz ne görüntü alır ne girdi gönderebilir (PLAN §5.4). İlk HELLO_ACK'ten sonraki her şey şifreli ve kimliği doğrulanmıştır (§9).

## 4. Mesaj tipleri

| Tip | Ad | Yön | Bağlantı | Fixture |
|---|---|---|---|---|
| 0x01 | HELLO | C→H | kontrol | `hello`, `hello_utf8_name` |
| 0x02 | HELLO_ACK | H→C | kontrol | `hello_ack`, `hello_ack_pending`, `hello_ack_busy` |
| 0x03 | STREAM_CONFIG | H→C | kontrol | `stream_config` |
| 0x04 | BYE | iki yön | kontrol | `bye` |
| 0x10 | PEN | C→H | kontrol | `pen_hover_to_contact`, `pen_leave`, `pen_eraser`, `pen_extremes`, `invalid_pen_count_zero` |
| 0x11 | KEY | C→H | kontrol | `key_down`, `key_up_caps`, `key_no_scan`, `invalid_key_short` |
| 0x12 | POINTER_REL | C→H | kontrol | `pointer_rel` |
| 0x13 | POINTER_ABS | C→H | kontrol | `pointer_abs` |
| 0x14 | SCROLL | C→H | kontrol | `scroll_began`, `scroll`, `scroll_ended` |
| 0x15 | PEN_GESTURE | C→H | kontrol | `pen_gesture` |
| 0x16 | RELEASE_ALL | C→H | kontrol | `release_all` |
| 0x17 | PINCH | C→H | kontrol | `pinch_began`, `pinch`, `pinch_ended` |
| 0x20 | PING | iki yön | kontrol | `ping` |
| 0x21 | PONG | iki yön | kontrol | `pong` |
| 0x22 | STATS | C→H | kontrol | `stats` |
| 0x23 | KEYFRAME_REQUEST | C→H | kontrol | `keyframe_request` |
| 0x40 | VIDEO_HELLO | C→H | video | `video_hello` |
| 0x41 | VIDEO_FRAME | H→C | video | `video_frame`, `video_frame_config` |
| — | (bilinmeyen) | — | — | `unknown_type` |

Aralıklar: `0x01–0x0F` oturum, `0x10–0x1F` girdi, `0x20–0x2F` bakım/istatistik, `0x40–0x4F` video. `invalid_*` fixture'ları **reddedilmesi** gereken girdilerdir. `unknown_type` ise **atlanması** gereken bir çerçevedir.

### 0x01 HELLO (C→H)

| Alan | Tip | Açıklama |
|---|---|---|
| protocol_version | u16 | `1` |
| device_id | bytes[16] | Kurulumda üretilen rastgele kimlik. Host eşleşmeyi bununla hatırlar. |
| screen_width_px | u16 | Tabletin fiziksel ekranı (MatePad: 2800) |
| screen_height_px | u16 | (MatePad: 1840) |
| density_dpi | u16 | `DisplayMetrics.densityDpi` (MatePad: 360) |
| max_refresh_hz | u16 | Desteklenen en yüksek yenileme (MatePad: 144) |
| capabilities | u32 | Bit alanı, aşağıda |
| device_name | str8 | Mac'teki onay penceresinde gösterilir. Loglanmaz. |
| client_nonce | bytes[16] | Her bağlantıda yeni rastgele değer (§9) |
| client_eph_pub | bytes[65] | Bu bağlantı için üretilen geçici P-256 açık anahtarı, sıkıştırılmamış (`0x04 ‖ X ‖ Y`) (§9) |

`capabilities`: bit0 `PEN`, bit1 `PEN_HOVER`, bit2 `PEN_TILT`, bit3 `KEYBOARD`, bit4 `TOUCHPAD` (pointer capture ile göreli hareket + kaydırma), bit5 `TOUCH` (ekrana parmakla dokunma), bit6 `DECODE_H264`, bit7 `DECODE_HEVC`.

### 0x02 HELLO_ACK (H→C)

| Alan | Tip | Açıklama |
|---|---|---|
| protocol_version | u16 | Host'un sürümü |
| status | u8 | `0` ACCEPTED, `1` PENDING_APPROVAL, `2` REJECTED, `3` VERSION_MISMATCH, `4` BUSY |
| reserved | u8 | |
| session_id | u32 | ACCEPTED'da rastgele ve sıfırdan farklı. Diğer durumlarda 0. |
| video_port | u16 | ACCEPTED'da video TCP portu, diğer durumlarda 0 |
| host_name | str8 | İstemcide gösterilir (boş olabilir) |
| key_mode | u8 | `0` NONE (terminal cevap, şifreleme yok), `1` PAIRED (eşleşme anahtarıyla), `2` PAIRING (yeni eşleşme; kod karşılaştırılır). Bilinmeyen değer protokol hatası. |
| host_id | bytes[16] | Host'un kalıcı rastgele kimliği; istemci eşleşme anahtarını bununla saklar. NONE'da sıfır. |
| host_nonce | bytes[16] | Her bağlantıda yeni rastgele değer. NONE'da sıfır. |
| host_eph_pub | bytes[65] | Host'un geçici P-256 açık anahtarı. NONE'da sıfır. |

Şifreli gelen ikinci `HELLO_ACK` (PENDING sonrası ACCEPTED ya da REJECTED) aynı alanları taşır ama `key_mode = NONE` ve anahtar alanları sıfırdır; istemci anahtar alanlarına bakmaz.

### 0x03 STREAM_CONFIG (H→C)

| Alan | Tip | Açıklama |
|---|---|---|
| config_id | u16 | Her yeni ayarda artar (1'den başlar) |
| codec | u8 | `1` H.264, `2` HEVC |
| reserved | u8 | |
| width_px | u16 | Kodlanan görüntü = sanal ekranın piksel boyutu |
| height_px | u16 | |
| width_pt | u16 | Sanal ekranın Mac nokta boyutu (HiDPI'da piksel/2). İstemci göreli hareket ve kaydırmayı bununla ölçekler. |
| height_pt | u16 | |
| fps | u16 | Hedef kare hızı |
| bitrate_kbps | u32 | Hedef bit hızı |
| color_primaries | u8 | ITU-T H.273 kodu: `1` BT.709/sRGB, `12` Display P3 |
| transfer | u8 | H.273: `1` BT.709, `13` sRGB |
| matrix | u8 | H.273: `1` BT.709 |
| full_range | u8 | `1` tam aralık, `0` sınırlı |

### 0x04 BYE (iki yön, kontrol)

| Alan | Tip | Açıklama |
|---|---|---|
| reason | u8 | `0` NORMAL, `1` PROTOCOL_ERROR, `2` REJECTED, `3` TIMEOUT, `4` SHUTTING_DOWN, `5` SUPERSEDED |

Gönderen `BYE`'dan sonra iki bağlantıyı da kapatır. Host, `BYE` aldığında veya gönderdiğinde önce release-all uygular (§7).

### 0x10 PEN (C→H)

Kalem örnekleri **toplu** gönderilir. Bir Android `MotionEvent`'in bütün geçmiş (historical) örnekleri ve güncel örneği tek mesajda, zaman sırasıyla gider. Tablet kalemi yaklaşık 330 Hz örnekliyor (3 ms). Ara örnekler atılmaz.

| Alan | Tip | Açıklama |
|---|---|---|
| tool | u8 | `0` PEN, `1` ERASER. Diğer değerler protokol hatası. |
| count | u8 | **1–64** örnek. 0 veya 64'ten büyük değer protokol hatasıdır. |
| reserved | u16 | |
| base_time_us | u64 | İlk örneğin zamanı |
| samples | count × 16 bayt | Aşağıda. Payload en az `12 + 16 × count` bayt olmalı. |

Örnek (16 bayt):

| Alan | Tip | Açıklama |
|---|---|---|
| dt_us | u32 | `base_time_us`'tan fark. Mesaj içinde **azalmayan** sırada olmalı, aksi protokol hatası. |
| x | u16 | Normalize (§1) |
| y | u16 | Normalize |
| pressure | u16 | 0…65535. `CONTACT` yoksa 0. |
| tilt_x | i16 | −1…1 (§1). Pozitif: kalemin üst ucu sağa (+x) yatık. |
| tilt_y | i16 | −1…1. Pozitif: üst uç aşağıya (+y, kullanıcıya doğru) yatık. |
| flags | u8 | bit0 `IN_RANGE` (yakınlıkta: hover veya temas), bit1 `CONTACT` (ekrana değiyor), bit2 `BUTTON` (kalem yan tuşu; Aşama 0'da hiç görülmedi, doğrulanmadı), bit3 `STROKE_START` (yalnızca bir temasın ilk örneğinde, yani Android `ACTION_DOWN` örneğinde; `CONTACT` ile birlikte) |
| reserved | u8 | |

`CONTACT` her zaman `IN_RANGE` ile, `STROKE_START` her zaman `CONTACT` ile birlikte gelir. `CONTACT=1, IN_RANGE=0` gelirse host bunu `flags = 0` sayar. İstemci `BUTTON` bitini Android `buttonState`'ten doldurur; host bu biti şimdilik **yok sayar** (karar 0006).

**Eğim yönü:** Mac tarafında `tilt_x`/`tilt_y` doğrudan `NSEvent.tilt` anlamındadır: x −1 sol … +1 sağ, y −1 üst … +1 alt. Android dönüşümü **geçicidir ve cihazda kalibre edilecektir**: `θ = AXIS_TILT` (0 = dik), `φ = AXIS_ORIENTATION` (0 = yukarı, saat yönünde pozitif), `tilt_x = sin θ · sin φ`, `tilt_y = −sin θ · cos φ`. Aşama 0'da temas sırasında eğimin seyrek güncellendiği görüldü. İstemci son bilinen değeri tekrarlar.

**Menzil canlılığı:** Kalem `IN_RANGE` iken istemci yaklaşık **100 ms**'de bir, en geç **150 ms**'de bir PEN mesajı gönderir. Yeni örnek yoksa son örneği güncel zamanla tekrarlar. Tekrarlanan örnek `STROKE_START` **taşımaz** (bayrak yalnızca gerçek `ACTION_DOWN` örneğindedir). Host bunu watchdog için kullanır (§7). Android `HOVER_EXIT` göndermeden kalem kaybolsa bile Mac'te kalem takılı kalmaz.

**İstemci kuralları:**
- `ACTION_HOVER_EXIT` ve kalemin menzilden çıkması `flags = 0` olan bir örnekle bildirilir. Android her `ACTION_DOWN`'dan hemen önce de `HOVER_EXIT` gönderir; istemci bu yüzden çıkışı en çok **~65 ms** bekletebilir ve arkasından `ACTION_DOWN` gelirse bildirmez (vuruşlar arasında yakınlık açılıp kapanmasın diye). Bekletilen çıkış hiçbir zaman atılmaz: süre dolunca, release-all'da ya da DOWN olmayan ilk olayda gönderilir.
- `ACTION_CANCEL` de `flags = 0` olan bir örnek olarak gönderilir.
- Avuç (FINGER tool) örnekleri PEN'e girmez.
- **Son çare korumaları:** Android hiç olay göndermezse istemci hover'ı **2 sn**, teması **10 sn** sonra `flags = 0` ile kendisi kapatır. Bunlar kilit kurmaz ve host watchdog'unun yerini tutmaz.

**Host durum makinesi:** tek bir fiziksel kalem vardır, bu yüzden aynı anda en çok **bir** araç menzildedir. Host etkin aracı ve onun önceki örneğinin durumunu tutar (oturum başında ve her release-all sonrasında `flags = 0`).

| Geçiş | Host'un ürettiği |
|---|---|
| `IN_RANGE` 0→1 | tablet proximity **enter** (araç tipiyle) |
| `CONTACT` 0→1 | mouse **down** (tablet-point alt tipi, basınçla). Aynı örnekte enter da yeniyse önce enter, sonra down. |
| `CONTACT` 1→1 | mouse **dragged** |
| `CONTACT` 1→0 | mouse **up** |
| `IN_RANGE` 1→1, temas yok | mouse **moved** (hover) |
| `IN_RANGE` 1→0 | temas sürüyorsa önce mouse **up**, sonra proximity **leave** |
| `tool` değişti | eski araç için up (gerekirse) + leave, yeni araç için enter |
| `STROKE_START`, temas sürerken | mouse **up** + mouse **down** (yeni vuruş). İstemci bunu normalde üretmez: iki vuruş arasında her zaman `CONTACT=0` olan bir örnek vardır (§5). |

- **Bırakma araçtan bağımsızdır:** `IN_RANGE=0` olan bir örnek, hangi `tool` değeriyle gelirse gelsin etkin aracı kapatır (up gerekirse + leave). Bir bırakma hiçbir zaman "yanlış araç" diye yok sayılmaz.
- **Etkin araç:** host'ta silgi modu açıksa (0x15 `PEN_GESTURE`, karar 0006) `tool=PEN` örnekler silgi sayılır. Mod değişimi bir sonraki PEN örneğinde `tool` değişti satırıyla uygulanır.

**Kilit (latch) kuralı:** **Oturum başında** ve **her** release-all'dan sonra (§7, sebebi ne olursa olsun) her araç için kilit kurulur. Kilit varken `CONTACT=1` örnekler yeni bir basış **sayılmaz** ve yalnızca hover olarak işlenir. Kilit, `CONTACT=0` olan bir örnek veya `STROKE_START` bayraklı bir örnek geldiğinde kalkar. Bu kural, gecikmiş gelen eski vuruş **ortası** örneklerinin Mac'te sürükleme başlatmasını önler. Yeni bir vuruş `STROKE_START` ile hemen başlar.

- Temas sürerken araç değişirse (çift dokunmayla silgi modu dahil) **yeni araç kilitli başlar**: vuruşun kalanı hover olarak işlenir, yeni araçla çizmek için kalemi kaldırıp yeniden basmak gerekir.
- **Watchdog kilit kurmaz** (§7). Watchdog kapanışından sonra gelen vuruş ortası örnekleri yeni bir vuruş başlatır; kısa bir ağ takılmasında çizginin kalanı kaybolmaz, iki vuruşa bölünür.

**Kabul edilen davranış:** Bağlantı tıkanıp host watchdog'u çalıştıktan sonra, kuyrukta bekleyen bir vuruş (tam ya da yarıda kalmış) geç de olsa çizilir. Bu takılı girdi yaratmaz, çünkü vuruşun bırakma örneği aynı sıralı akışta arkasından gelir. Gecikmenin üst sınırı istemci kuyruk sınırıdır (§5, 1 sn).

### 0x11 KEY (C→H)

Karar 0003'e göre karakter değil **fiziksel tuş** gönderilir. Karakteri Mac'teki giriş kaynağı ("Türkçe Q") üretir.

| Alan | Tip | Açıklama |
|---|---|---|
| time_us | u64 | Olay zamanı |
| scan_code | u16 | Linux evdev kodu (`KeyEvent.getScanCode()`), ör. A=30, Esc=1, CapsLock=58. Bilinmiyorsa 0. |
| android_key_code | u16 | `KeyEvent.getKeyCode()`. `scan_code = 0` olan tuşlar için yedek. |
| action | u8 | `0` UP, `1` DOWN. Diğer değerler protokol hatası. |
| lock_state | u8 | bit0 `CAPS_LOCK`: olay **sonrası** Caps Lock durumu (`metaState & META_CAPS_LOCK_ON`) |
| reserved | u16 | |

**Tuş kimliği:** `scan_code != 0` ise `scan_code`, değilse `0x10000 + android_key_code`. İkisi de 0 ise olay gönderilmez.

**İstemci kuralları:**
- `repeatCount > 0` olan olaylar **gönderilmez** (tekrarı host üretir, aşağıda).
- Esc aynı scan code (1) ile hem `KEYCODE_ESCAPE` hem `KEYCODE_BACK` üretir. **BACK gönderilmez** ve uygulama tarafından tüketilir, yoksa Esc uygulamadan çıkar.
- Her DOWN için bir UP gönderilir. Uygulama odak kaybederse `RELEASE_ALL` gönderilir.

**Host kuralları:**
- **Eşleme:** tuş kimliği → macOS virtual keycode tablosu `MateBridgeCore`'da tutulur. Değiştirici eşlemesi (ör. Ctrl→Cmd) bir ayardır, protokolün parçası değildir.
- **Takılmayan bırakma:** host DOWN anında enjekte ettiği virtual keycode'u tuş kimliğiyle kaydeder. UP'ta **kaydedileni** bırakır. Böylece tuş basılıyken eşleme ayarı değişse bile doğru tuş bırakılır.
- **Tekrarlı olaylar:** zaten basılı bir tuş için ikinci DOWN yok sayılır. Basılı olmayan tuş için UP da yok sayılır.
- **Değiştiriciler:** değiştirici tuşlar `flagsChanged` olayı olarak enjekte edilir ve sonraki bütün olayların `flags` alanına yansıtılır.
- **Otomatik tekrar:** sentetik `CGEvent` tuşları macOS'ta kendiliğinden tekrarlamaz. Host, değiştirici olmayan **son** basılan tuş için macOS'un tuş tekrar ayarlarıyla (`NSEvent.keyRepeatDelay` / `keyRepeatInterval`) tekrar üretir. Tekrar, o tuşun UP'unda, başka bir tuşun DOWN'unda ve her release-all'da durur. **Aşama 1'de cihazda doğrulanacak.**
- **Caps Lock:** Caps tuşunun DOWN/UP olayları Mac'e tuş olarak **enjekte edilmez**. Host, Caps tuşunun UP olayındaki ve diğer bütün KEY olaylarındaki `lock_state.CAPS_LOCK` değerini Mac'in Caps Lock durumuyla karşılaştırır. Farklıysa Mac'in kilit durumunu doğrudan ayarlar (ör. `IOHIDSetModifierLockState`). Caps tuşunun DOWN olayındaki `lock_state` kullanılmaz, çünkü Android durumu tuşu bıraktıktan sonra günceller.

### 0x12 POINTER_REL (C→H)

Trackpad (pointer capture) veya fareden gelen göreli hareket.

| Alan | Tip | Açıklama |
|---|---|---|
| time_us | u64 | |
| dx | f32 | Mac **nokta** cinsinden yatay hareket. Hassasiyet ve ivme istemcide uygulanır. Ölçek `STREAM_CONFIG.width_pt`'dir. |
| dy | f32 | Dikey hareket, +y aşağı |
| buttons | u8 | Basılı düğmeler: bit0 LEFT, bit1 RIGHT, bit2 MIDDLE, bit3 BACK, bit4 FORWARD |
| reserved | u8 | |
| reserved2 | u16 | |

Düğme durumu her mesajda **tam** olarak gönderilir. Host önceki durumla karşılaştırıp down/up üretir. Yalnızca düğme değişen olaylarda `dx = dy = 0` olur. Çift tıklama için `clickState`'i host üretir: macOS çift tıklama süresi ve mesafesi içinde art arda gelen basışlar sayılır.

### 0x13 POINTER_ABS (C→H)

Ekrana parmakla dokunma veya capture dışındaki fare. İmleci mutlak konuma taşır.

| Alan | Tip | Açıklama |
|---|---|---|
| time_us | u64 | |
| x | u16 | Normalize (§1) |
| y | u16 | Normalize |
| buttons | u8 | POINTER_REL ile aynı. Parmak temas ederken `LEFT`. |
| source | u8 | `0` TOUCH, `1` MOUSE |
| reserved | u16 | |

### 0x14 SCROLL (C→H)

Pointer capture'daki ham iki parmak hareketinden istemcinin ürettiği hassas kaydırma. Aşama 0'da HarmonyOS normal modda kaydırma olayı vermiyordu, iki parmak hareketini dokunmatik sürüklemeye çeviriyordu. Fare tekerleği de bu mesajla gelir (`phase = NONE`).

| Alan | Tip | Açıklama |
|---|---|---|
| time_us | u64 | |
| dx | f32 | Parmakların hareketi, Mac nokta cinsinden, +x sağ. Tekerlekte istemci bir tık = 10 pt varsayar (ayar). |
| dy | f32 | +y aşağı |
| phase | u8 | `0` NONE (tekerlek, tekil), `1` BEGAN, `2` CHANGED, `3` ENDED, `4` CANCELLED |
| reserved | u8 | |
| reserved2 | u16 | |

- Doğal kaydırma yönü, ölçek ve atalet (momentum) host'ta uygulanır. Protokol yalnızca parmak hareketini taşır.
- Her BEGAN'ın ardından ENDED veya CANCELLED gelmesi zorunludur.
- **Hareket canlılığı:** hareket açıkken parmaklar durursa istemci en geç **200 ms**'de bir `CHANGED` (`dx = dy = 0`) gönderir; host watchdog'u (§7) bununla beslenir. Host sıfır deltalı `CHANGED` için Mac'e olay enjekte etmez. Parmaklar **5 sn** hiç hareket etmezse istemci hareketi `ENDED` ile kapatır; aynı parmaklar yeniden hareket ederse yeni bir `BEGAN` ile başlar. Böylece canlılık mesajı, kaybolmuş bir parmak kalkışını sonsuza kadar örtemez.
- Host kuralları: BEGAN olmadan gelen CHANGED/ENDED yok sayılır. Açık bir hareket varken yeni BEGAN gelirse önce eskisi bitirilir.
- **Zorla bitirme:** host'un kendi bitirdiği hareket (yeni BEGAN, watchdog, release-all; §7) Mac'e **ENDED** olarak gider ve ardından **atalet üretilmez**. İstemciden gelen `CANCELLED` ise Mac'e iptal olarak gider.

### 0x15 PEN_GESTURE (C→H)

Kalemin kendi hareketleri. M-Pencil'in çift dokunması ayrı bir Bluetooth cihazından `keyCode 718 / scanCode 190` olarak iki kısa DOWN/UP çifti üretir. İstemci bunu tek bir hareket olarak gönderir ve bu tuş olaylarını KEY olarak **göndermez**.

| Alan | Tip | Açıklama |
|---|---|---|
| time_us | u64 | |
| gesture | u8 | `1` DOUBLE_TAP. Bilinmeyen değerler yok sayılır. |
| reserved | u8 | |
| reserved2 | u16 | |

Host'taki karşılığı bir ayardır. Varsayılan (karar 0006): `DOUBLE_TAP` **silgi modunu** açıp kapatır. Mod oturum boyunca kalır; release-all'da ve oturum sonunda kalem moduna döner.

### 0x16 RELEASE_ALL (C→H)

Host bu oturumun basılı tuttuğu her şeyi bırakır (§7).

| Alan | Tip | Açıklama |
|---|---|---|
| reason | u8 | `0` USER, `1` BACKGROUND, `2` FOCUS_LOST, `3` DEVICE_DETACHED |

İstemci bunu şu durumlarda gönderir: uygulama arka plana geçtiğinde, pencere odağı kaybolduğunda, pointer capture kapandığında, bir girdi cihazı ayrıldığında, video görünümü gizlendiğinde (ör. bağlantı paneli açıldığında; `reason = USER`).

### 0x17 PINCH (C→H)

İki parmakla yakınlaştırma (Faz 3, kullanıcı isteği 2026-09-30). Mac'te trackpad'in büyütme hareketi olarak enjekte edilir (Krita'da tuval yakınlaştırma, Safari/Preview'da sayfa yakınlaştırma). Dokunmatik ekrandan ya da pointer capture altındaki touchpad'den gelir.

| Alan | Tip | Açıklama |
|---|---|---|
| time_us | u64 | |
| scale | f32 | Önceki PINCH mesajından bu yana göreli ölçek değişimi: `d_şimdi / d_önceki − 1` (parmaklar arası uzaklık). `+` açılma (yakınlaş), `−` kapanma. BEGAN ve ENDED'de `0`. |
| x | u16 | Normalize (§1) hareket merkezi (iki parmağın ortası). Yalnızca `source = TOUCH` iken anlamlı; TOUCHPAD'de `0`. |
| y | u16 | Normalize merkez |
| phase | u8 | `1` BEGAN, `2` CHANGED, `3` ENDED, `4` CANCELLED (SCROLL ile aynı numaralar; `0` geçersiz) |
| source | u8 | `0` TOUCH (dokunmatik ekran), `1` TOUCHPAD |
| reserved | u16 | |

**İstemci kuralları:**
- İki parmak hareketi **ya** kaydırma (SCROLL) **ya** yakınlaştırmadır, hareket boyunca değişmez. Karar ilk anlamlı harekette verilir: parmaklar arası uzaklığın göreli değişimi, ortak kaydırma hareketinden baskınsa PINCH (eşik istemcide, sabit ya da ayar).
- Her BEGAN'ın ardından ENDED veya CANCELLED gelir. SCROLL'daki canlılık kuralı aynen geçerlidir: hareket açıkken en geç **200 ms**'de bir `CHANGED` (`scale = 0`), parmaklar **5 sn** hareketsizse `ENDED`.
- Dokunmatik ekrandan gelen PINCH, PROTOCOL §7'deki parmak kuralına tabidir: kalem `IN_RANGE` iken ve son PEN'den sonraki 1 sn boyunca yeni PINCH başlatılmaz.
- Tek bir mesajdaki `scale` `[-0,5, 1,0]` aralığına sıkıştırılır.

**Host kuralları:**
- Aynı anda tek bir açık PINCH olur; açık SCROLL ile de birlikte olamaz. PINCH BEGAN geldiğinde açık SCROLL ya da PINCH varsa önce o zorla bitirilir (§4 SCROLL zorla bitirme). SCROLL BEGAN geldiğinde açık PINCH de aynı şekilde bitirilir.
- Sol düğmenin sahibi varken (sürükleme sürüyor) PINCH BEGAN yok sayılır; o hareketin CHANGED/ENDED'i de yok sayılır. BEGAN olmadan gelen CHANGED/ENDED yok sayılır.
- `source = TOUCH` ise host BEGAN'da imleci merkeze taşır (sürüklemesiz fare hareketi), çünkü macOS uygulamaları büyütmeyi imleç konumunda uygular. TOUCHPAD'de imleç yerinde kalır.
- Mac'e giden olay: büyütme hareketi (başla / değişim = `scale` / bitti). Sıfır `scale`'li CHANGED enjekte edilmez. **CANCELLED Mac'e "bitti" olarak gider** (Qt'de iptalin karşılığı yok; hareket açık kalırdı).
- Zorla bitirme (yeni BEGAN, watchdog, release-all, kapı kapanması) Mac'e "bitti" olarak gider.

### 0x20 PING / 0x21 PONG (iki yön)

PING:

| Alan | Tip | Açıklama |
|---|---|---|
| seq | u32 | Artan sıra |
| sender_time_us | u64 | Gönderenin saati |

PONG (PING'i alan taraf hemen cevaplar):

| Alan | Tip | Açıklama |
|---|---|---|
| seq | u32 | PING'deki sıra |
| echo_time_us | u64 | PING'deki `sender_time_us` aynen |
| responder_time_us | u64 | Cevaplayanın saati |

### 0x22 STATS (C→H)

İstemci her `interval_ms`'de (varsayılan 1000) bir gönderir. Host ekran üstü göstergeyi ve logları bununla besler.

| Alan | Tip | Açıklama |
|---|---|---|
| interval_ms | u32 | Pencere uzunluğu |
| frames_received | u32 | Pencerede alınan kare |
| frames_decoded | u32 | |
| frames_rendered | u32 | |
| frames_dropped | u32 | Eskidiği için atılan (§5) |
| decode_time_avg_us | u32 | Decoder'a veriş → çıkış |
| latency_avg_us | u32 | Yakalama → ekranda gösterim, saat farkı düzeltilmiş tahmin (§6). Bilinmiyorsa 0. |
| bytes_received | u32 | Video bağlantısından alınan bayt |

### 0x23 KEYFRAME_REQUEST (C→H)

| Alan | Tip | Açıklama |
|---|---|---|
| reason | u8 | `0` STARTUP, `1` DECODE_ERROR, `2` FRAMES_DROPPED |

Host bir sonraki kareyi keyframe olarak kodlar. Art arda gelen istekler birleştirilebilir. Sebep `STARTUP`, `DECODE_ERROR` ya da bilinmeyen ise host o keyframe'den önce güncel `CODEC_CONFIG`'i **yeniden gönderir** (istemci çözücüsünü yeniden kurmuş ve eski parametre setlerini atmış olabilir); `FRAMES_DROPPED` için göndermez. İstemci akış ortasında gelen, öncekiyle aynı `CODEC_CONFIG`'i kabul eder.

### 0x40 VIDEO_HELLO (C→H, video bağlantısı)

| Alan | Tip | Açıklama |
|---|---|---|
| protocol_version | u16 | `1` |
| config_id | u16 | İstemcinin uyguladığı `STREAM_CONFIG.config_id` |
| session_id | u32 | `HELLO_ACK`'teki değer |
| video_nonce | bytes[16] | Her video bağlantısında yeni rastgele değer; bu bağlantının anahtarları buradan türetilir (§9) |

### 0x41 VIDEO_FRAME (H→C, video bağlantısı)

| Alan | Tip | Açıklama |
|---|---|---|
| frame_seq | u32 | Bu video bağlantısında her karede 1 artar, 0'dan başlar (CODEC_CONFIG dahil) |
| capture_time_us | u64 | ScreenCaptureKit karesinin host monoton zamanı |
| flags | u8 | bit0 `KEYFRAME`, bit1 `CODEC_CONFIG` (yalnızca parametre setleri: H.264 SPS/PPS, HEVC VPS/SPS/PPS) |
| reserved | u8 | Codec bu bağlantının `STREAM_CONFIG`'inden bilinir |
| fragment_index | u16 | TCP'de `0` |
| fragment_count | u16 | TCP'de `1` |
| reserved2 | u16 | |
| frame_size | u32 | Karenin tüm parçalarının toplam veri boyutu. TCP'de bu mesajdaki `data` uzunluğudur. |
| data | bytes[frame_size] | Annex-B NAL birimleri (`00 00 00 01` başlangıç kodlarıyla). Tam olarak `frame_size` bayt. Payload bundan sonra devam ederse fazlası gelecekteki alanlardır ve yok sayılır (§2). |

`fragment_*` ve `frame_size` alanları ileride UDP'ye geçiş için ayrılmıştır (PLAN §4). v0'da her kare tek parçadır. TCP'de `fragment_index ≠ 0`, `fragment_count ≠ 1` veya payload'da `24 + frame_size` bayttan az veri olması **protokol hatasıdır** (video bağlantısı kapanır, §2).

## 5. Kuyruk sınırları (AGENTS.md: yalnızca sınırlı kuyruk)

**Video:**
- Host: kodlayıcı çıkışı ile soket arasında en çok **2** kare bekler. Soket yetişemiyorsa eski, keyframe olmayan kareler atılır ve bir sonraki kare keyframe olarak istenir.
- İstemci: decoder'a verilmeyi bekleyen en çok **2** kare tutulur. Taşarsa en eski kareler atılır ve `frames_dropped` artar. Referans zinciri koptuğu için `KEYFRAME_REQUEST(FRAMES_DROPPED)` gönderilir. Keyframe gelene kadar gelen keyframe olmayan kareler decoder'a verilmez.

**Kontrol + girdi (istemci gönderim kuyruğu):**
- En çok **256 KiB** veya en eski mesaj **1 sn**.
- Tıkanma varken birleştirilebilecekler:
  - ardışık hover PEN örnekleri (yalnız `IN_RANGE`, son örnek kalır),
  - ardışık `POINTER_REL` (dx/dy toplanır, `buttons` aynıysa),
  - ardışık `SCROLL` CHANGED (dx/dy toplanır),
  - ardışık `PINCH` CHANGED (`scale`: `(1+a)(1+b) − 1`, merkez sonuncununki).
- **Durum geçişleri asla birleştirilmez veya atılmaz:** `CONTACT`/`IN_RANGE` değişen örnekler, `KEY`, düğme değişimi, SCROLL ve PINCH BEGAN/ENDED/CANCELLED, `RELEASE_ALL`.
- Sınır birleştirmeye rağmen aşılırsa istemci bağlantıyı kapatıp yeniden bağlanır. Host bağlantı kopunca release-all uygular (§7). Böylece bir bırakma olayı hiçbir zaman sessizce kaybolmaz.

## 6. Heartbeat ve saat farkı

- İstemci her **500 ms**'de bir `PING` gönderir. Host da aynı aralıkla gönderebilir.
- Host kontrol bağlantısından **1.500 ms** boyunca hiçbir mesaj almazsa **release-all** uygular (bağlantıyı kapatmaz). **5.000 ms** olursa bağlantıyı kapatır. Onay beklenirken (PENDING) 5 sn kuralı uygulanmaz, 60 sn onay süresi geçerlidir.
- İstemci **3.000 ms** boyunca `PONG` alamazsa bağlantıyı kapatıp yeniden bağlanır (§3.3 devralma).
- Saat farkı tahmini (istemci):
  - `rtt = now − echo_time_us`
  - `offset = responder_time_us − (echo_time_us + rtt/2)`, en düşük `rtt`'li son örneklerle
  - `latency = gösterim_zamanı − (capture_time_us − offset)`

## 7. Girdi güvenliği (AGENTS.md: girdi asla takılı kalmaz)

**Release-all**, host'un bu oturum için tuttuğu **bütün** girdi durumunu bırakıp sıfırlaması demektir:
- basılı tuşlar için UP (kayıtlı virtual keycode ile) ve otomatik tekrarın durması,
- basılı fare düğmeleri için up,
- kalem teması için up ve yakınlık için leave, araç başına `flags = 0` ve reset sonrası kuralı (§4 PEN), silgi modunun kapanması,
- açık kaydırma hareketi için ENDED (ataletsiz, §4 SCROLL) ve süren ataletin durması,
- açık yakınlaştırma hareketi için "bitti" (§4 PINCH).

İşaretçi kaynaklarının **bildirdiği** düğme durumu release-all'da sıfırlanmaz (aşağıda "işaretçi kilidi"). Host her oturum için girdi durumunu sıfırdan kurar; bir oturumun durumu sonrakine taşınmaz.

**Tetikleyiciler** (her biri tek başına yeterli):
- `RELEASE_ALL` mesajı, `BYE` (gelen veya giden)
- kontrol bağlantısının kopması veya protokol hatası
- 1.500 ms heartbeat sessizliği
- oturumun devralınması (§3.3)
- host uygulamasının kapanması

**Girdi watchdog'ları** (bağlantı canlı olsa bile, çünkü PING girdi yolunu kanıtlamaz):
- Kalem `IN_RANGE` iken **500 ms** PEN gelmezse host o araç için up (temas varsa) + leave üretir ve `flags = 0` sayar.
- SCROLL hareketi açıkken **500 ms** SCROLL gelmezse host hareketi bitirir (zorla bitirme, §4 SCROLL).
- PINCH hareketi açıkken **500 ms** PINCH gelmezse host hareketi bitirir (§4 PINCH).
- Süre host'un **tek** monoton saatiyle, mesajın **alındığı** ana göre ölçülür (mesajdaki `*_time_us` kullanılmaz). Her girdi mesajı işlenmeden önce süresi dolmuş watchdog'lar uygulanır: önce kapanış, sonra mesaj. Böylece sonuç zamanlayıcının ne zaman çalıştığına bağlı olmaz. Saat geri gitmiş görünürse süre o andan yeniden başlatılır; watchdog en kötü 500 ms gecikir, hiçbir zaman devre dışı kalmaz.
- Watchdog kapanışı release-all **değildir**: kilit kurmaz (§4), silgi modunu ve diğer kaynakları etkilemez.

**Kaynak ayrımı:** Host her kaynak için (kalem teması, `POINTER_REL`, `POINTER_ABS source=MOUSE`, `POINTER_ABS source=TOUCH`) basılı düğmeleri **ayrı** tutar.
- **Sol düğmenin tek sahibi vardır.** Sahip olmayan bir kaynağın sol düğme basışı ve bırakışı Mac'e gitmez, yalnızca o kaynağın kendi durumunu günceller.
- **Kalem önceliklidir:** Kalem teması başladığında (`CONTACT` 0→1) sol düğme başka bir kaynaktaysa, host önce o kaynak adına **up** üretir, sonra kalem için tablet-point **down** üretir. Böylece çizim programı kalem vuruşunu her zaman ayrı ve basınçlı bir vuruş olarak görür. Önceki sahibin sonraki bırakışı etkisizdir. Tekrar basmak için önce bırakıp yeniden basması gerekir.
- Kalem temas halindeyken başka kaynakların sol düğme basışları yok sayılır.
- Sağ, orta, geri ve ileri düğmeleri için Mac'e giden durum, kaynakların birleşimidir (OR). Birleşik durum 0→1 olunca down, 1→0 olunca up üretilir.
- Kalem `IN_RANGE` iken ve son PEN mesajından sonraki **1 sn** boyunca (karar 0006) `POINTER_ABS source=TOUCH` mesajlarındaki **yeni basışlar** yok sayılır (avuç reddi). **Sahibin bırakışı asla yok sayılmaz:** dokunma kaynağı sol düğmenin sahibiyse, kalem menzildeyken de bırakılır.
- **İmleç hareketi:** sol düğmenin sahibi varken diğer kaynakların imleç hareketi (kalem hover dahil) Mac'e gitmez. Basışı kabul edilmemiş bir parmak imleci taşımaz.
- **İşaretçi kilidi:** `POINTER_*` mesajları kenar değil **tam durum** taşır; host basış/bırakışı kaynağın son bildirdiği duruma göre hesaplar ve bu bildirilen durumu release-all'da **sıfırlamaz**. Release-all anında basılı bildirilmiş bir düğme, o kaynak onu bırakılmış bildirene kadar yeni basış sayılmaz. Kalemdeki kilidin karşılığıdır: gecikmiş bir "hâlâ basılı" mesajı hayalet tık ya da sürükleme üretmez.

**İstemcinin yükümlülükleri:**
- İstemci bir DOWN gönderdiyse ilgili UP'u da gönderir. Göndermeden bağlantı koparsa host release-all ile telafi eder.
- **Tek sıralı gönderim:** Bütün girdi mesajları ve `RELEASE_ALL`, olayların üretildiği sırayla **tek bir FIFO**'ya yazılır. Android'de girdi olayları ve yaşam döngüsü çağrıları (`onPause`, odak kaybı) aynı UI iş parçacığında gelir; kuyruğa oradan, o sırayla yazılır. Başka bir iş parçacığı girdi mesajı üretmez.
- `RELEASE_ALL`'dan sonra istemci, ilgili cihaz/odak geri gelene kadar girdi göndermez. Geri geldiğinde kalem için ilk temas örneği `STROKE_START` taşımıyorsa (vuruşun ortası) temas olarak gönderilmez, yalnızca hover olarak gönderilir.
- **Temas doğrulama (karar 0007):** istemci bir kalem temasını ancak doğrulanınca gönderir: aynı temastan ikinci örnek gelince (bırakış olayının taşıdığı geçmiş örnekler dahil) ya da basıştan **10 ms** sonra. Hiç olay gelmezse süre bir sonraki zamanlayıcı adımında dolar (tablette ≈35 ms'ye kadar; kalem hareketsizken de örnek gönderdiği için pratikte ≈3 ms). Bundan önce biten temas (kalem ucunun sekmesi: tek örneklik DOWN ve hemen UP) **hiç gönderilmez**; ne `STROKE_START` ne bırakış. Doğrulanan temasın bekletilen örnekleri özgün zaman damgalarıyla gider. Tel biçimi değişmez; host için fark yoktur.
- **İşaretçi düğmeleri ve `RELEASE_ALL`:** istemci `RELEASE_ALL` göndermeden **hemen önce**, o anda basılı bildirdiği her işaretçi kaynağı için `buttons = 0` olan bir mesaj gönderir (`POINTER_ABS`'ta son bilinen konumla). Sonrasında bir düğmeyi yalnızca **yeni bir basış olayı** gördüğünde basılı bildirir (parmakta `ACTION_DOWN`, farede `ACTION_BUTTON_PRESS`). Odak geri geldiğinde hâlâ basılı olan düğme ya da süren dokunuş, bırakılıp yeniden basılana kadar bildirilmez. Bu kural olmadan host'taki işaretçi kilidi, release-all'dan sonraki ilk dokunuşu yutardı.
- **Bırakışlar sınıflandırmaya bağlı değildir:** istemci bir parmağın ya da kalemin bırakışını (`ACTION_UP`, `ACTION_POINTER_UP`, `ACTION_CANCEL`) basışı izlediği **(cihaz kimliği, işaretçi kimliği)** çiftine göre eşler; olay anındaki araç tipi (`FINGER`, `PALM`, `UNKNOWN`) bırakışın gönderilmesini engellemez. Android işaretçi kimlikleri yalnızca tek bir girdi cihazı içinde benzersizdir; tablette kalem ve dokunmatik ekran ayrı cihazlardır ve ikisi de 0'dan numaralar. Bu yüzden yalnızca işaretçi kimliğiyle eşleme yapılmaz: avucun kalkışı kalem vuruşunu bitirmemelidir.
- **Parmak kapısı (istemci tarafı):** istemci de kalem menzildeyken ve gönderdiği **son PEN mesajından** sonraki **1,2 sn** boyunca yeni parmak basışı ve yeni kaydırma başlatmaz (gönderilen her PEN mesajı sayılır: canlılık tekrarları ve `flags = 0` dahil). İstemci süresi host'unkinden (1 sn, mesajın alındığı andan) 200 ms uzundur; böylece ağ gecikmesi değişse de istemcinin gönderdiği basış host'ta reddedilmez. Ağır tıkanmada uyuşmazlık yine olabilir: o dokunuş kaybolur, hiçbir şey basılı kalmaz. Kalem menzile girdiğinde basılı parmak bırakılır (`buttons = 0`) ve açık kaydırma `CANCELLED` ile kapatılır.
- **Parmak için son çare koruması:** basılı bir parmaktan **10 sn** hiç olay gelmezse istemci onu `buttons = 0` ile kapatır (kaydırma için §4 SCROLL'daki 5 sn kuralı).
- **`RELEASE_ALL` gönderilemezse** (kuyruk reddi ya da girdi yolunda hata) istemci bağlantıyı kapatır; host kopmada release-all uygular. İstemci kendi durumunu her iki halde de sıfırlar.

## 8. Fixture'lar

`protocol/fixtures/<ad>.hex` dosyaları başlık dahil tam çerçevedir: alan başına bir satır, yorumda alan adı ve değeri. Dosyalar `protocol/fixtures/gen.py` ile üretilir. `--check` güncelliği doğrular, `scripts/check.sh` bunu çalıştırır. Üreteç, kalem bayraklarının değişmezlerini de (`CONTACT` ⇒ `IN_RANGE`, basınç ⇒ `CONTACT`) denetler.

Swift ve Kotlin testleri:
1. Geçerli her fixture'ı decode eder, yorumdaki değerlerle karşılaştırır, aynı değerlerden aynı baytları encode eder.
2. `invalid_*` fixture'larının protokol hatası verdiğini doğrular.
3. `unknown_type`'ın atlandığını ve akışın devam ettiğini doğrular.

**Fixture listesi:**
- Oturum: `hello`, `hello_utf8_name`, `hello_ack`, `hello_ack_pending`, `hello_ack_busy`, `stream_config`, `bye`
- Kalem: `pen_hover_to_contact`, `pen_leave`, `pen_eraser`, `pen_extremes`, `invalid_pen_count_zero`, `pen_gesture`
- Klavye: `key_down`, `key_up_caps`, `key_no_scan`, `invalid_key_short`
- İşaretçi ve kaydırma: `pointer_rel`, `pointer_abs`, `scroll_began`, `scroll`, `scroll_ended`, `pinch_began`, `pinch`, `pinch_ended`
- Bakım: `release_all`, `ping`, `pong`, `stats`, `keyframe_request`
- Video: `video_hello`, `video_frame`, `video_frame_config`
- Diğer: `unknown_type`
- Şifreleme: `crypto_vectors.json` (§9)

## 9. Şifreleme (karar 0010)

Amaç: ev ağında (Wi-Fi) kontrol + girdi (yazılan şifreler dahil) ve görüntü şifreli ve kimliği doğrulanmış gitsin. USB'de de aynı yol kullanılır (tek kod yolu). Yalnızca platform kriptografisi: P-256 ECDH, HKDF-SHA256, AES-256-GCM (Swift CryptoKit; Android `KeyAgreement("ECDH")`, `Mac("HmacSHA256")`, `Cipher("AES/GCM/NoPadding")`).

**El sıkışma** (şifresiz, §3):
- İstemci her bağlantıda yeni bir geçici P-256 anahtar çifti ve 16 baytlık `client_nonce` üretir, `HELLO`'ya koyar.
- Host da yeni bir geçici anahtar çifti ve `host_nonce` üretir, ilk `HELLO_ACK`'e `key_mode`, `host_id`, `host_nonce`, `host_eph_pub` ile koyar.
- `ecdh` = P-256 ECDH paylaşılan sırrı, X koordinatı, 32 bayt. Geçersiz ya da eğri dışı açık anahtar protokol hatasıdır.
- `transcript_hash` = SHA-256(HELLO payload ‖ ilk HELLO_ACK payload) — çerçeve başlıkları hariç, baytlar teldeki gibi.

**Anahtar türetme** (RFC 5869 HKDF, SHA-256):
- `ikm` = PAIRED'de `pair_key (32) ‖ ecdh`, PAIRING'de yalnızca `ecdh`.
- `prk` = HKDF-Extract(salt = `transcript_hash`, ikm).
- Kontrol bağlantısı: `k_c2h` = Expand(prk, `"MB1 control c2h"`, 32), `k_h2c` = Expand(prk, `"MB1 control h2c"`, 32).
- Video bağlantısı: `kv_h2c` = Expand(prk, `"MB1 video h2c" ‖ video_nonce`, 32), `kv_c2h` = Expand(prk, `"MB1 video c2h" ‖ video_nonce`, 32). Host `prk`'yi oturum boyunca tutar; oturum bitince siler.
- PAIRING'de ayrıca: eşleşme kodu `sas` = Expand(prk, `"MB1 sas"`, 4) → u32 little-endian `mod 1 000 000`, 6 hane (baştaki sıfırlarla); yeni eşleşme anahtarı `new_pair_key` = Expand(prk, `"MB1 pair"`, 32).
- `info` dizeleri ASCII'dir, sonlandırıcı yoktur.

**Şifreli kayıt** (ilk HELLO_ACK'ten sonra kontrol bağlantısında iki yönde, VIDEO_HELLO'dan sonra video bağlantısında iki yönde):

| Alan | Tip | Açıklama |
|---|---|---|
| length | u32 | `ciphertext` + `tag` uzunluğu = düz metin + 16 |
| ciphertext | bytes | AES-256-GCM ile şifrelenmiş düz metin: `type (u8) ‖ payload` |
| tag | bytes[16] | GCM etiketi |

- Nonce (12 bayt) = `00 00 00 00 ‖ sayaç (u64 LE)`. Sayaç her bağlantıda ve her yönde **0'dan** başlar, her kayıtta 1 artar, asla tekrar etmez (2^63'e ulaşırsa bağlantı kapanır).
- AAD = `length` alanının 4 baytı.
- En büyük `length` = §2'deki payload sınırı + 17. Sınır başlık okunur okunmaz denetlenir.
- Etiket doğrulanamazsa ya da `length < 17` ise: protokol hatası; alıcı **BYE göndermeden** bağlantıyı kapatır (şifreli kanala güvenilmez). Kontrol bağlantısında bu, host için release-all tetikleyicisidir (§7, bağlantı kopması).
- Düz metin çözüldükten sonra `type` ve `payload` §2/§4 kurallarıyla işlenir (bilinmeyen tip atlanır, kısa payload hata).

**Eşleşme** (PAIRING):
- Host onay penceresinde, tablet "onay bekleniyor" ekranında **aynı `sas`** kodunu gösterir. Kullanıcı kodların aynı olduğunu görerek onaylar (ağdaki bir aracıya karşı koruma).
- Kabulde host `(device_id → new_pair_key, device_name)` kaydını saklar ve şifreli `HELLO_ACK(ACCEPTED)` gönderir; istemci bu mesajı alınca `(host_id → new_pair_key)` saklar. Bundan sonraki bağlantılar PAIRED'dir. Oturum, el sıkışmada türetilen anahtarlarla devam eder (anahtar değişmez).
- İstemcide bu `host_id` için anahtar varken host PAIRING isterse (host cihazı unutmuş) istemci kullanıcıya "Mac bu tableti tanımıyor, yeniden eşleşiliyor" uyarısını ve kodu gösterir; kabulde eski anahtarın yerine yenisini yazar.
- **Ön onay (T-043, yalnız host davranışı):** onay bekleyen bağlantı kapanırsa host onay penceresini 2 dk açık tutar. Kullanıcı bu sürede "İzin ver" derse o `device_id` için 2 dk'lık, tek kullanımlık ön onay kaydedilir; aynı cihazın sonraki PAIRING el sıkışması sormadan kabul edilir. Nedeni: başsız Mac'te onay penceresi yalnızca Parsec gibi başka bir yoldan görülebiliyor, bu da tablet uygulamasını arka plana düşürüp bağlantıyı kapatıyor. Bedeli: o 2 dk içinde ağdaki biri `device_id`'yi taklit edip eşleşebilir (kod karşılaştırması o bağlantı için yapılmamış olur). Tel biçimi değişmez.
- PAIRED'de istemci `host_id` için anahtarı yoksa bağlantıyı kapatır ve yeniden eşleşme gerektiğini gösterir (host menüsünden "Onaylı cihazları unut").

**Saklama:** eşleşme anahtarları gizlidir, **asla loglanmaz**. Host: macOS Anahtar Zinciri (generic password, hizmet `dev.matebridge.host.pair`, hesap = device_id hex). İstemci: Android Keystore'da üretilen dışa aktarılamaz bir AES-GCM anahtarıyla şifrelenip SharedPreferences'ta. `host_id` host'ta bir kez üretilir ve saklanır. "Onaylı cihazları unut" anahtarları da siler.

**Test vektörleri:** `protocol/fixtures/crypto_vectors.json` (`crypto_vectors.swift` ile üretilir; girdi olarak `hello.hex`, `hello_ack.hex`, `hello_ack_pending.hex` payload'larını kullanır). Her iki taraf: sabit özel anahtarlardan `ecdh`, iki moddaki `transcript_hash`, `prk`, bütün anahtarları, `sas` ve `new_pair_key`'i, ve `frames` altındaki şifreli kayıtları bayt bayt üretir; kayıtları çözer; bir baytı bozulmuş kaydı reddeder.
