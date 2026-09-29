# MateBridge protokolü — v0 (taslak)

**Durum:** v0 taslağı, T-007 (2026-09-29). `protocol_version = 0` kararsız sürüm demektir. Aşama 1–2'de gerçek kullanımla değişebilir. Değişiklik bu dosyada ve fixture'larda aynı commit'te yapılır. Kararlı hale gelince sürüm 1 olur. **Sahibi: orkestratör.**

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

**Çerçeve** (her iki bağlantıda aynı, 5 bayt başlık):

| Alan | Tip | Açıklama |
|---|---|---|
| `type` | u8 | Mesaj tipi (§4) |
| `length` | u32 | Yalnızca payload uzunluğu (başlık hariç) |
| payload | `length` bayt | Mesaja göre |

- **En büyük payload:** kontrol bağlantısında 65.536 bayt, video bağlantısında 16.777.216 bayt.
- **Bilinmeyen tip:** alıcı payload'u atlar ve devam eder (ileri uyumluluk, fixture `unknown_type`).
- **Uzunluk:** bilinen bir tip beklenenden **uzun** payload ile gelirse fazlası yok sayılır (yeni alanlar yalnızca sona eklenir). **Kısa** gelirse protokol hatasıdır (fixture `invalid_key_short`).
- **Protokol hatası:**
  - Kontrol bağlantısında: alıcı `BYE(PROTOCOL_ERROR)` gönderir, **iki bağlantıyı da** kapatır.
  - Video bağlantısında: alıcı **yalnızca video bağlantısını** kapatır, `BYE` göndermez. Host'ta hata loglanır. İstemci video bağlantısını yeniden açabilir (§3.5).

## 3. Oturum akışı

1. **Keşif:** Host Bonjour ile `_matebridge._tcp` hizmetini yayınlar (TXT: `v=0`). İstemci Android `NsdManager` ile bulur, ya da IP/port elle girilir.
2. **HELLO:** İstemci kontrol bağlantısını açar ve ilk mesaj olarak `HELLO` gönderir. Host ilk 5 sn içinde `HELLO` almazsa bağlantıyı kapatır.
3. **HELLO_ACK:**
   - `protocol_version` farklıysa `VERSION_MISMATCH`, bağlantı kapanır.
   - **Tek oturum:** host aynı anda tek oturum tutar.
     - Başka bir `device_id` ile aktif oturum varsa `BUSY` gönderilir ve bağlantı kapanır.
     - Aynı `device_id` ile yeni bir `HELLO` gelirse (yeniden bağlanma) eski oturum **devralınır**. Host eski oturumun girdi durumunu release-all ile bırakır, eski bağlantılara `BYE(SUPERSEDED)` gönderip kapatır. Yeni oturumu ancak bundan **sonra** kabul eder. Yarı açık kalmış eski TCP bağlantısı böylece yeni oturumun girdisine karışamaz.
   - `device_id` daha önce onaylanmışsa `ACCEPTED`.
   - Yeni cihazsa önce `PENDING_APPROVAL` ve Mac'te "MatePad bağlanmak istiyor → İzin ver" sorulur. Kabul edilirse ikinci bir `HELLO_ACK(ACCEPTED)` gelir. Reddedilirse veya **60 sn** içinde cevap yoksa `HELLO_ACK(REJECTED)` gelir ve bağlantı kapanır.
4. **STREAM_CONFIG:** `ACCEPTED` sonrası host `STREAM_CONFIG` gönderir.
5. **Video bağlantısı:** İstemci video bağlantısını `video_port`'a açar. İlk mesaj olarak `VIDEO_HELLO(session_id, config_id)` gönderir; `config_id` istemcinin uyguladığı son `STREAM_CONFIG`'dir. Host, `session_id` veya `config_id` güncel değilse video bağlantısını kapatır.
6. **Video akışı:** Host `VIDEO_FRAME` akışına başlar: önce `CODEC_CONFIG`, sonra keyframe.
7. **Ayar değişikliği** (çözünürlük, codec, FPS): Host yeni `config_id` ile `STREAM_CONFIG` gönderir, sonra mevcut video bağlantısını kapatır. İstemci yeni ayarı uygulayıp yeni `config_id` ile video bağlantısını yeniden açar. Böylece bir video bağlantısındaki bütün kareler tek bir ayara aittir ve iki bağlantı arasındaki sıra sorunu oluşmaz.

**Onay öncesi:** `ACCEPTED` gelmeden istemci girdi mesajı **göndermez**. Gelirse host yok sayar ve hiçbir olay enjekte edilmez. `PING/PONG`, `HELLO` alındıktan sonra her durumda (onay beklerken de) geçerlidir ve cevaplanır.

Onaylanmamış cihaz ne görüntü alır ne girdi gönderebilir (PLAN §5.4). Şifreleme Aşama 4'te gelecek. v0 yalnızca ev ağı içindir.

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
| protocol_version | u16 | v0 için `0` |
| device_id | bytes[16] | Kurulumda üretilen rastgele kimlik. Host eşleşmeyi bununla hatırlar. |
| screen_width_px | u16 | Tabletin fiziksel ekranı (MatePad: 2800) |
| screen_height_px | u16 | (MatePad: 1840) |
| density_dpi | u16 | `DisplayMetrics.densityDpi` (MatePad: 360) |
| max_refresh_hz | u16 | Desteklenen en yüksek yenileme (MatePad: 144) |
| capabilities | u32 | Bit alanı, aşağıda |
| device_name | str8 | Mac'teki onay penceresinde gösterilir. Loglanmaz. |

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

`CONTACT` her zaman `IN_RANGE` ile, `STROKE_START` her zaman `CONTACT` ile birlikte gelir. `CONTACT=1, IN_RANGE=0` gelirse host bunu `flags = 0` sayar.

**Eğim yönü:** Mac tarafında `tilt_x`/`tilt_y` doğrudan `NSEvent.tilt` anlamındadır: x −1 sol … +1 sağ, y −1 üst … +1 alt. Android dönüşümü **geçicidir ve cihazda kalibre edilecektir**: `θ = AXIS_TILT` (0 = dik), `φ = AXIS_ORIENTATION` (0 = yukarı, saat yönünde pozitif), `tilt_x = sin θ · sin φ`, `tilt_y = −sin θ · cos φ`. Aşama 0'da temas sırasında eğimin seyrek güncellendiği görüldü. İstemci son bilinen değeri tekrarlar.

**Menzil canlılığı:** Kalem `IN_RANGE` iken istemci en az **100 ms**'de bir PEN mesajı gönderir. Yeni örnek yoksa son örneği güncel zamanla tekrarlar. Host bunu watchdog için kullanır (§7). Android `HOVER_EXIT` göndermeden kalem kaybolsa bile Mac'te kalem takılı kalmaz.

**İstemci kuralları:**
- `ACTION_HOVER_EXIT` ve kalemin menzilden çıkması `flags = 0` olan bir örnekle bildirilir.
- `ACTION_CANCEL` de `flags = 0` olan bir örnek olarak gönderilir.
- Avuç (FINGER tool) örnekleri PEN'e girmez.

**Host durum makinesi:** her araç için önceki örneğin durumu tutulur (başlangıçta ve her release-all sonrasında `flags = 0`).

| Geçiş | Host'un ürettiği |
|---|---|
| `IN_RANGE` 0→1 | tablet proximity **enter** (araç tipiyle) |
| `CONTACT` 0→1 | mouse **down** (tablet-point alt tipi, basınçla). Aynı örnekte enter da yeniyse önce enter, sonra down. |
| `CONTACT` 1→1 | mouse **dragged** |
| `CONTACT` 1→0 | mouse **up** |
| `IN_RANGE` 1→1, temas yok | mouse **moved** (hover) |
| `IN_RANGE` 1→0 | temas sürüyorsa önce mouse **up**, sonra proximity **leave** |
| `tool` değişti | eski araç için up (gerekirse) + leave, yeni araç için enter |

**Kilit (latch) kuralı:** **Her** release-all'dan sonra (§7, sebebi ne olursa olsun) her araç için kilit kurulur. Kilit varken `CONTACT=1` örnekler yeni bir basış **sayılmaz** ve yalnızca hover olarak işlenir. Kilit, `CONTACT=0` olan bir örnek veya `STROKE_START` bayraklı bir örnek geldiğinde kalkar. Bu kural, gecikmiş gelen eski vuruş **ortası** örneklerinin Mac'te sürükleme başlatmasını önler. Yeni bir vuruş `STROKE_START` ile hemen başlar.

**Kabul edilen davranış:** Bağlantı tıkanıp host watchdog'u çalıştıktan sonra, kuyrukta bekleyen **tam** bir vuruş (`STROKE_START`…bırakma) geç de olsa çizilir. Bu takılı girdi yaratmaz, çünkü vuruşun bırakma örneği aynı sıralı akışta arkasından gelir. Gecikmenin üst sınırı istemci kuyruk sınırıdır (§5, 1 sn).

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
- Host kuralları: BEGAN olmadan gelen CHANGED/ENDED yok sayılır. Açık bir hareket varken yeni BEGAN gelirse önce eskisi bitirilir.

### 0x15 PEN_GESTURE (C→H)

Kalemin kendi hareketleri. M-Pencil'in çift dokunması ayrı bir Bluetooth cihazından `keyCode 718 / scanCode 190` olarak iki kısa DOWN/UP çifti üretir. İstemci bunu tek bir hareket olarak gönderir ve bu tuş olaylarını KEY olarak **göndermez**.

| Alan | Tip | Açıklama |
|---|---|---|
| time_us | u64 | |
| gesture | u8 | `1` DOUBLE_TAP. Bilinmeyen değerler yok sayılır. |
| reserved | u8 | |
| reserved2 | u16 | |

Host'taki karşılığı bir ayardır (ör. silgiye geç, geri al).

### 0x16 RELEASE_ALL (C→H)

Host bu oturumun basılı tuttuğu her şeyi bırakır (§7).

| Alan | Tip | Açıklama |
|---|---|---|
| reason | u8 | `0` USER, `1` BACKGROUND, `2` FOCUS_LOST, `3` DEVICE_DETACHED |

İstemci bunu şu durumlarda gönderir: uygulama arka plana geçtiğinde, pencere odağı kaybolduğunda, pointer capture kapandığında, bir girdi cihazı ayrıldığında.

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

Host bir sonraki kareyi keyframe olarak kodlar. Art arda gelen istekler birleştirilebilir.

### 0x40 VIDEO_HELLO (C→H, video bağlantısı)

| Alan | Tip | Açıklama |
|---|---|---|
| protocol_version | u16 | `0` |
| config_id | u16 | İstemcinin uyguladığı `STREAM_CONFIG.config_id` |
| session_id | u32 | `HELLO_ACK`'teki değer |

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
| frame_size | u32 | Karenin tüm parçalarının toplam veri boyutu. TCP'de bu mesajdaki veri uzunluğuna eşit. |
| data | bytes | Annex-B NAL birimleri (`00 00 00 01` başlangıç kodlarıyla) |

`fragment_*` ve `frame_size` alanları ileride UDP'ye geçiş için ayrılmıştır (PLAN §4). v0'da her kare tek parçadır.

## 5. Kuyruk sınırları (AGENTS.md: yalnızca sınırlı kuyruk)

**Video:**
- Host: kodlayıcı çıkışı ile soket arasında en çok **2** kare bekler. Soket yetişemiyorsa eski, keyframe olmayan kareler atılır ve bir sonraki kare keyframe olarak istenir.
- İstemci: decoder'a verilmeyi bekleyen en çok **2** kare tutulur. Taşarsa en eski kareler atılır ve `frames_dropped` artar. Referans zinciri koptuğu için `KEYFRAME_REQUEST(FRAMES_DROPPED)` gönderilir. Keyframe gelene kadar gelen keyframe olmayan kareler decoder'a verilmez.

**Kontrol + girdi (istemci gönderim kuyruğu):**
- En çok **256 KiB** veya en eski mesaj **1 sn**.
- Tıkanma varken birleştirilebilecekler:
  - ardışık hover PEN örnekleri (yalnız `IN_RANGE`, son örnek kalır),
  - ardışık `POINTER_REL` (dx/dy toplanır, `buttons` aynıysa),
  - ardışık `SCROLL` CHANGED (dx/dy toplanır).
- **Durum geçişleri asla birleştirilmez veya atılmaz:** `CONTACT`/`IN_RANGE` değişen örnekler, `KEY`, düğme değişimi, SCROLL BEGAN/ENDED/CANCELLED, `RELEASE_ALL`.
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
- kalem teması için up ve yakınlık için leave, araç başına `flags = 0` ve reset sonrası kuralı (§4 PEN),
- açık kaydırma hareketi için ENDED.

**Tetikleyiciler** (her biri tek başına yeterli):
- `RELEASE_ALL` mesajı, `BYE` (gelen veya giden)
- kontrol bağlantısının kopması veya protokol hatası
- 1.500 ms heartbeat sessizliği
- oturumun devralınması (§3.3)
- host uygulamasının kapanması

**Girdi watchdog'ları** (bağlantı canlı olsa bile, çünkü PING girdi yolunu kanıtlamaz):
- Kalem `IN_RANGE` iken **500 ms** PEN gelmezse host o araç için up (temas varsa) + leave üretir ve `flags = 0` sayar.
- SCROLL hareketi açıkken **500 ms** SCROLL gelmezse host hareketi bitirir.

**Kaynak ayrımı:** Host her kaynak için (kalem teması, `POINTER_REL`, `POINTER_ABS source=MOUSE`, `POINTER_ABS source=TOUCH`) basılı düğmeleri **ayrı** tutar.
- **Sol düğmenin tek sahibi vardır.** Sahip olmayan bir kaynağın sol düğme basışı ve bırakışı Mac'e gitmez, yalnızca o kaynağın kendi durumunu günceller.
- **Kalem önceliklidir:** Kalem teması başladığında (`CONTACT` 0→1) sol düğme başka bir kaynaktaysa, host önce o kaynak adına **up** üretir, sonra kalem için tablet-point **down** üretir. Böylece çizim programı kalem vuruşunu her zaman ayrı ve basınçlı bir vuruş olarak görür. Önceki sahibin sonraki bırakışı etkisizdir. Tekrar basmak için önce bırakıp yeniden basması gerekir.
- Kalem temas halindeyken başka kaynakların sol düğme basışları yok sayılır.
- Sağ, orta, geri ve ileri düğmeleri için Mac'e giden durum, kaynakların birleşimidir (OR). Birleşik durum 0→1 olunca down, 1→0 olunca up üretilir.
- Kalem `IN_RANGE` iken `POINTER_ABS source=TOUCH` mesajlarındaki **yeni basışlar** yok sayılır (avuç reddi). **Sahibin bırakışı asla yok sayılmaz:** dokunma kaynağı sol düğmenin sahibiyse, kalem menzildeyken de bırakılır.

**İstemcinin yükümlülükleri:**
- İstemci bir DOWN gönderdiyse ilgili UP'u da gönderir. Göndermeden bağlantı koparsa host release-all ile telafi eder.
- **Tek sıralı gönderim:** Bütün girdi mesajları ve `RELEASE_ALL`, olayların üretildiği sırayla **tek bir FIFO**'ya yazılır. Android'de girdi olayları ve yaşam döngüsü çağrıları (`onPause`, odak kaybı) aynı UI iş parçacığında gelir; kuyruğa oradan, o sırayla yazılır. Başka bir iş parçacığı girdi mesajı üretmez.
- `RELEASE_ALL`'dan sonra istemci, ilgili cihaz/odak geri gelene kadar girdi göndermez. Geri geldiğinde kalem için ilk temas örneği `STROKE_START` taşımıyorsa (vuruşun ortası) temas olarak gönderilmez, yalnızca hover olarak gönderilir.

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
- İşaretçi ve kaydırma: `pointer_rel`, `pointer_abs`, `scroll_began`, `scroll`, `scroll_ended`
- Bakım: `release_all`, `ping`, `pong`, `stats`, `keyframe_request`
- Video: `video_hello`, `video_frame`, `video_frame_config`
- Diğer: `unknown_type`
