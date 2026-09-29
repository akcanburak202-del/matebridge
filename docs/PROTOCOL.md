# MateBridge protokolü — v0 (taslak)

**Durum:** v0 taslağı, T-007 (2026-09-29). `protocol_version = 0` kararsız sürüm demektir. Aşama 1–2'de gerçek kullanımla değişebilir, değişiklikler bu dosyada ve fixture'larda aynı commit'te yapılır. Kararlı hale gelince sürüm 1 olur. **Sahibi: orkestratör.**

Bu dosya Swift ve Kotlin tarafının tek ortak sözleşmesidir. Tasarım Aşama 0 ölçümlerine dayanır (`docs/NOTES.md`, 2026-09-29).

## 1. Genel kurallar

- **Bayt sırası:** tüm sayılar **little-endian**. `f32` IEEE-754 binary32.
- **Tipler:** `u8/u16/u32/u64` işaretsiz, `i16` işaretli (ikiye tümleyen), `str8` = `u8 uzunluk` + UTF-8 bayt (en çok 64 bayt, sonlandırıcı yok), `bytes` = ham bayt.
- **Hizalama yok:** alanlar dolgu olmadan art arda gelir. Açıkça yazılmış `reserved` alanları gönderen tarafından **0** yazılır, alıcı tarafından **yok sayılır**.
- **Yön:** C = istemci (tablet), H = host (Mac).
- **Zaman:** `*_time_us` alanları gönderenin **monoton** saatidir, mikrosaniye. İki tarafın saatleri karşılaştırılmaz; fark PING/PONG ile tahmin edilir (bkz. §6). Android API 31'de olay zamanları milisaniye çözünürlüklüdür (`eventTime × 1000`).
- **Normalize koordinat:** `x`, `y` (`u16`) tabletin **video yüzeyi** üzerinde konumdur: `0` = sol/üst kenar, `65535` = sağ/alt kenar. İstemci: `x = round(clamp(px / surface_width, 0, 1) × 65535)`. Host: `x_pt = x / 65535 × display_width_pt`. Video yüzeyi ekranın tamamı değilse (siyah bant) istemci bandı çıkarıp hesaplar; yüzey dışındaki noktalar kenara sıkıştırılır (clamp).

## 2. Bağlantılar ve çerçeveleme

İki ayrı TCP bağlantısı vardır. Büyük video kareleri girdi olaylarını bekletmesin diye ayrılır (head-of-line blocking).

| Bağlantı | Port | Seçenekler | İçerik |
|---|---|---|---|
| **Kontrol + girdi** | Bonjour ile bulunur (§3) | `TCP_NODELAY` her iki uçta | Oturum, girdi, heartbeat, istatistik. Sıralı ve kayıpsız: bırakma olayları asla kaybolmaz. |
| **Video** | `HELLO_ACK.video_port` | `TCP_NODELAY` | Yalnızca `VIDEO_HELLO` (C→H) ve `VIDEO_FRAME` (H→C). |

USB kullanımında aynı bağlantılar `adb reverse` ile taşınır; protokol değişmez.

**Çerçeve** (her iki bağlantıda aynı):

| Alan | Tip | Açıklama |
|---|---|---|
| `type` | u8 | Mesaj tipi (§4) |
| `length` | u32 | Yalnızca payload uzunluğu (başlık hariç) |
| payload | `length` bayt | Mesaja göre |

- **En büyük payload:** kontrol bağlantısında 65.536 bayt, video bağlantısında 16.777.216 bayt. Aşılırsa alıcı `BYE(PROTOCOL_ERROR)` gönderip bağlantıyı kapatır.
- **Bilinmeyen tip:** alıcı payload'u atlayıp devam eder (ileri uyumluluk). Bilinen bir tip, beklenenden **uzun** payload ile gelirse fazlası yok sayılır; **kısa** gelirse protokol hatasıdır.
- **Yeni alanlar** yalnızca payload'un **sonuna** eklenir.

## 3. Oturum akışı

1. Host Bonjour ile `_matebridge._tcp` hizmetini yayınlar (TXT: `v=0`). İstemci Android `NsdManager` ile bulur ya da IP/port elle girilir.
2. İstemci kontrol bağlantısını açar ve ilk mesaj olarak `HELLO` gönderir. Host ilk 5 sn içinde `HELLO` almazsa bağlantıyı kapatır.
3. Host `HELLO_ACK` ile cevap verir:
   - `device_id` daha önce onaylanmışsa `ACCEPTED`.
   - Yeni cihazsa önce `PENDING_APPROVAL`; Mac'te "MatePad bağlanmak istiyor → İzin ver" sorulur. Kullanıcı kabul ederse ikinci bir `HELLO_ACK(ACCEPTED)`, reddederse `HELLO_ACK(REJECTED)` ve bağlantı kapanır.
   - `protocol_version` farklıysa `VERSION_MISMATCH` ve bağlantı kapanır.
4. `ACCEPTED` sonrası host `STREAM_CONFIG` gönderir. İstemci video bağlantısını `video_port`'a açar ve ilk mesaj olarak `VIDEO_HELLO(session_id)` gönderir. `session_id` tutmazsa host video bağlantısını kapatır.
5. Host `VIDEO_FRAME` akışına başlar: önce `CODEC_CONFIG`, sonra keyframe.
6. **`ACCEPTED` gelmeden** istemcinin gönderdiği girdi mesajları host tarafından **yok sayılır** ve hiçbir olay enjekte edilmez.

Onaylanmamış cihaz ne görüntü alır ne girdi gönderebilir (PLAN §5.4). Şifreleme Aşama 4'te gelir; v0 yalnızca ev ağı içindir.

## 4. Mesaj tipleri

| Tip | Ad | Yön | Bağlantı | Fixture |
|---|---|---|---|---|
| 0x01 | HELLO | C→H | kontrol | `hello` |
| 0x02 | HELLO_ACK | H→C | kontrol | `hello_ack`, `hello_ack_pending` |
| 0x03 | STREAM_CONFIG | H→C | kontrol | `stream_config` |
| 0x04 | BYE | iki yön | kontrol | `bye` |
| 0x10 | PEN | C→H | kontrol | `pen_hover_to_contact`, `pen_leave`, `pen_eraser` |
| 0x11 | KEY | C→H | kontrol | `key_down`, `key_up_caps` |
| 0x12 | POINTER_REL | C→H | kontrol | `pointer_rel` |
| 0x13 | POINTER_ABS | C→H | kontrol | `pointer_abs` |
| 0x14 | SCROLL | C→H | kontrol | `scroll` |
| 0x15 | PEN_GESTURE | C→H | kontrol | `pen_gesture` |
| 0x16 | RELEASE_ALL | C→H | kontrol | `release_all` |
| 0x20 | PING | iki yön | kontrol | `ping` |
| 0x21 | PONG | iki yön | kontrol | `pong` |
| 0x22 | STATS | C→H | kontrol | `stats` |
| 0x23 | KEYFRAME_REQUEST | C→H | kontrol | `keyframe_request` |
| 0x40 | VIDEO_HELLO | C→H | video | `video_hello` |
| 0x41 | VIDEO_FRAME | H→C | video | `video_frame`, `video_frame_config` |

Aralıklar: `0x01–0x0F` oturum, `0x10–0x1F` girdi, `0x20–0x2F` bakım/istatistik, `0x40–0x4F` video.

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

`capabilities`: bit0 `PEN`, bit1 `PEN_HOVER`, bit2 `PEN_TILT`, bit3 `KEYBOARD`, bit4 `TOUCHPAD` (pointer capture ile göreli hareket + kaydırma), bit5 `TOUCH` (ekrana parmakla dokunma), bit6 `DECODE_H264`, bit7 `DECODE_HEVC`. Diğer bitler 0.

### 0x02 HELLO_ACK (H→C)

| Alan | Tip | Açıklama |
|---|---|---|
| protocol_version | u16 | Host'un sürümü |
| status | u8 | `0` ACCEPTED, `1` PENDING_APPROVAL, `2` REJECTED, `3` VERSION_MISMATCH |
| reserved | u8 | 0 |
| session_id | u32 | ACCEPTED'da rastgele, sıfırdan farklı. Diğer durumlarda 0. |
| video_port | u16 | ACCEPTED'da video TCP portu, diğer durumlarda 0 |
| host_name | str8 | İstemcide gösterilir |

### 0x03 STREAM_CONFIG (H→C)

Video başlamadan önce ve akış ayarı değiştiğinde (çözünürlük, codec, FPS) gönderilir. Değişiklikten sonraki ilk `VIDEO_FRAME` bir `CODEC_CONFIG`, ardından keyframe olur.

| Alan | Tip | Açıklama |
|---|---|---|
| codec | u8 | `1` H.264, `2` HEVC |
| reserved | u8 | 0 |
| width_px | u16 | Kodlanan görüntü (sanal ekranın piksel boyutu) |
| height_px | u16 | |
| fps | u16 | Hedef kare hızı |
| bitrate_kbps | u32 | Hedef bit hızı |
| color_primaries | u8 | ITU-T H.273 kodu: `1` BT.709/sRGB, `12` Display P3 |
| transfer | u8 | H.273: `1` BT.709, `13` sRGB |
| matrix | u8 | H.273: `1` BT.709 |
| full_range | u8 | `1` tam aralık, `0` sınırlı |

### 0x04 BYE (iki yön)

| Alan | Tip | Açıklama |
|---|---|---|
| reason | u8 | `0` NORMAL, `1` PROTOCOL_ERROR, `2` REJECTED, `3` TIMEOUT, `4` SHUTTING_DOWN |

Gönderen, `BYE`'dan sonra bağlantıyı kapatır. Host, `BYE` aldığında veya bağlantı koptuğunda önce **release-all** uygular (§7).

### 0x10 PEN (C→H)

Kalem örnekleri **toplu** gönderilir: bir Android `MotionEvent`'in bütün geçmiş (historical) örnekleri ve güncel örneği tek mesajda, zaman sırasıyla. Tablet kalemi ~330 Hz örnekliyor (3 ms). Ara örnekler atılmaz.

| Alan | Tip | Açıklama |
|---|---|---|
| tool | u8 | `0` PEN, `1` ERASER |
| count | u8 | 1–64 örnek |
| reserved | u16 | 0 |
| base_time_us | u64 | İlk örneğin zamanı |
| samples | count × 16 bayt | Aşağıda |

Örnek (16 bayt):

| Alan | Tip | Açıklama |
|---|---|---|
| dt_us | u32 | `base_time_us`'tan fark |
| x | u16 | Normalize (§1) |
| y | u16 | Normalize |
| pressure | u16 | `round(clamp(p, 0, 1) × 65535)`. Temas yoksa 0. |
| tilt_x | i16 | −32767…32767 = −1…1. Pozitif: kalemin üst ucu sağa (+x) yatık. |
| tilt_y | i16 | −32767…32767 = −1…1. Pozitif: üst uç aşağıya (+y, kullanıcıya doğru) yatık. |
| flags | u8 | bit0 `IN_RANGE` (yakınlıkta: hover veya temas), bit1 `CONTACT` (ekrana değiyor), bit2 `BUTTON` (kalem yan tuşu). Diğer bitler 0. |
| reserved | u8 | 0 |

**Android → tilt dönüşümü (geçici, cihazda kalibre edilecek):** `θ = AXIS_TILT` (0 = dik), `φ = AXIS_ORIENTATION` (0 = yukarı, saat yönünde pozitif). `tilt_x = sin θ · sin φ`, `tilt_y = −sin θ · cos φ`. Aşama 0'da temas sırasında eğimin seyrek güncellendiği görüldü; istemci son bilinen değeri tekrarlar.

**Durum makinesi (host):** host her araç için önceki örneğin `flags` değerini tutar ve geçişlerden olay üretir. `CONTACT` her zaman `IN_RANGE` ile birlikte gelir.

| Geçiş | Host'un ürettiği |
|---|---|
| `IN_RANGE` 0→1 | tablet proximity **enter** (araç tipiyle) |
| `CONTACT` 0→1 | mouse **down** (tablet-point alt tipi, basınçla) |
| `CONTACT` 1→1 | mouse **dragged** |
| `CONTACT` 1→0 | mouse **up** |
| `IN_RANGE` 1→1, temas yok | mouse **moved** (hover) |
| `IN_RANGE` 1→0 | temas sürüyorsa önce mouse **up**, sonra proximity **leave** |
| `tool` değişti | eski araç için up (gerekirse) + leave, yeni araç için enter |

İstemci kuralları: `ACTION_HOVER_EXIT` ve kalemin menzilden çıkması `flags = 0` olan bir örnekle bildirilir. `ACTION_CANCEL` de temas kesilmiş örnek (`flags = 0`) olarak gönderilir. Avuç (FINGER tool) örnekleri PEN'e girmez.

### 0x11 KEY (C→H)

Karar 0003: karakter değil **fiziksel tuş** gönderilir. Karakteri Mac'teki giriş kaynağı ("Türkçe Q") üretir.

| Alan | Tip | Açıklama |
|---|---|---|
| time_us | u64 | Olay zamanı |
| scan_code | u16 | Linux evdev kodu (`KeyEvent.getScanCode()`), ör. A=30, Esc=1, CapsLock=58. Bilinmiyorsa 0. |
| android_key_code | u16 | `KeyEvent.getKeyCode()`. Yedek: `scan_code = 0` olan tuşlar için. |
| action | u8 | `0` UP, `1` DOWN |
| lock_state | u8 | bit0 `CAPS_LOCK`, bit1 `NUM_LOCK`, bit2 `SCROLL_LOCK` (olay anındaki `metaState`'ten) |
| reserved | u16 | 0 |

İstemci kuralları:
- `repeatCount > 0` olan olaylar **gönderilmez**. Tekrarı macOS kendisi üretir.
- Esc aynı scan code (1) ile hem `KEYCODE_ESCAPE` hem `KEYCODE_BACK` üretir. **BACK gönderilmez** ve uygulama tarafından tüketilir, yoksa Esc uygulamadan çıkar.
- Her DOWN için bir UP gönderilmesi zorunludur. Uygulama odak kaybederse `RELEASE_ALL` gönderilir.

Host kuralları: scan code → macOS virtual keycode eşleme tablosu `MateBridgeCore`'da tutulur. Değiştirici eşlemesi (ör. Ctrl→Cmd) ayardır, protokolün parçası değildir. `lock_state.CAPS_LOCK` Mac'teki Caps Lock durumundan farklıysa host Caps Lock'u eşitler.

### 0x12 POINTER_REL (C→H)

Trackpad (pointer capture) veya fareden gelen göreli hareket.

| Alan | Tip | Açıklama |
|---|---|---|
| time_us | u64 | |
| dx | f32 | Mac **nokta** (point) cinsinden yatay hareket; hassasiyet/ivme istemcide uygulanmış |
| dy | f32 | Dikey hareket, +y aşağı |
| buttons | u8 | Basılı düğmeler: bit0 LEFT, bit1 RIGHT, bit2 MIDDLE |
| reserved | u8 | 0 |
| reserved2 | u16 | 0 |

Düğme durumu her mesajda tam olarak gönderilir. Host önceki durumla karşılaştırıp down/up üretir. Yalnız düğme değişen olaylarda `dx = dy = 0` olur.

### 0x13 POINTER_ABS (C→H)

Ekrana parmakla dokunma veya capture dışındaki fare: imleci mutlak konuma taşır.

| Alan | Tip | Açıklama |
|---|---|---|
| time_us | u64 | |
| x | u16 | Normalize (§1) |
| y | u16 | Normalize |
| buttons | u8 | POINTER_REL ile aynı. Parmak temas ederken `LEFT`. |
| source | u8 | `0` TOUCH, `1` MOUSE |
| reserved | u16 | 0 |

### 0x14 SCROLL (C→H)

Pointer capture'daki ham iki parmak hareketinden istemcinin ürettiği hassas kaydırma. (Aşama 0: HarmonyOS normal modda kaydırma olayı vermiyor, iki parmak hareketini dokunmatik sürüklemeye çeviriyor.)

| Alan | Tip | Açıklama |
|---|---|---|
| time_us | u64 | |
| dx | f32 | Parmakların hareketi, Mac nokta cinsinden, +x sağ |
| dy | f32 | +y aşağı |
| phase | u8 | `0` NONE (tekerlek gibi tekil), `1` BEGAN, `2` CHANGED, `3` ENDED, `4` CANCELLED |
| momentum_phase | u8 | `0` NONE, `1` BEGAN, `2` CHANGED, `3` ENDED. v0'da istemci 0 gönderir; ataleti gerekirse host üretir. |
| reserved | u16 | 0 |

Doğal kaydırma yönü ve ölçek host'ta uygulanır. Protokol yalnızca parmak hareketini taşır. Her BEGAN'ın ardından ENDED veya CANCELLED gelmesi zorunludur.

### 0x15 PEN_GESTURE (C→H)

Kalemin kendi hareketleri. M-Pencil'in çift dokunması ayrı bir Bluetooth cihazından `keyCode 718 / scanCode 190` olarak iki kısa DOWN/UP çifti üretir; istemci bunu tek bir hareket olarak gönderir.

| Alan | Tip | Açıklama |
|---|---|---|
| time_us | u64 | |
| gesture | u8 | `1` DOUBLE_TAP |
| reserved | u8 | 0 |
| reserved2 | u16 | 0 |

Host'ta karşılığı ayardır (ör. silgiye geç / geri al).

### 0x16 RELEASE_ALL (C→H)

Host basılı her tuşu, fare düğmesini ve kalem temasını bırakır, kalemi yakınlıktan çıkarır ve kaydırma sürüyorsa bitirir.

| Alan | Tip | Açıklama |
|---|---|---|
| reason | u8 | `0` USER, `1` BACKGROUND, `2` FOCUS_LOST, `3` DEVICE_DETACHED |

İstemci bunu uygulama arka plana geçtiğinde, pencere odağı kaybolduğunda, pointer capture kapandığında ve bir girdi cihazı ayrıldığında gönderir.

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

İstemci her `interval_ms`'de (varsayılan 1000) bir gönderir. Host ekran üstü göstergeyi ve logları besler.

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
| reserved | u16 | 0 |
| session_id | u32 | `HELLO_ACK`'teki değer |

### 0x41 VIDEO_FRAME (H→C, video bağlantısı)

| Alan | Tip | Açıklama |
|---|---|---|
| frame_seq | u32 | Her karede 1 artar (CODEC_CONFIG dahil) |
| capture_time_us | u64 | ScreenCaptureKit karesinin host monoton zamanı |
| flags | u8 | bit0 `KEYFRAME`, bit1 `CODEC_CONFIG` (yalnızca parametre setleri: H.264 SPS/PPS, HEVC VPS/SPS/PPS) |
| codec | u8 | `1` H.264, `2` HEVC |
| fragment_index | u16 | TCP'de `0` |
| fragment_count | u16 | TCP'de `1` |
| reserved | u16 | 0 |
| frame_size | u32 | Karenin tüm parçalarının toplam veri boyutu. TCP'de bu mesajdaki veri uzunluğuna eşit. |
| data | bytes | Annex-B NAL birimleri (`00 00 00 01` başlangıç kodlarıyla) |

`fragment_*` alanları ileride UDP'ye geçiş için ayrılmıştır. v0'da her kare tek parçadır.

## 5. Video kuyruğu kuralları (AGENTS.md: sınırlı kuyruk)

- Host: kodlayıcı çıkışı ile soket arasında en çok **2** kare bekler. Soket yetişemiyorsa **eski** keyframe olmayan kareler atılır ve bir sonraki kare keyframe olarak istenir.
- İstemci: decoder'a verilmeyi bekleyen en çok **2** kare tutulur. Taşarsa en eski kareler atılır, `frames_dropped` artar ve referans zinciri koptuğu için `KEYFRAME_REQUEST(FRAMES_DROPPED)` gönderilir. Keyframe gelene kadar gelen keyframe olmayan kareler decoder'a verilmez.

## 6. Heartbeat ve saat farkı

- İstemci her **500 ms**'de bir `PING` gönderir. Host da aynı aralıkla gönderebilir.
- Host kontrol bağlantısından **1.500 ms** boyunca hiçbir mesaj almazsa **release-all** uygular (bağlantıyı kapatmaz). **5.000 ms** olursa bağlantıyı kapatır.
- İstemci **3.000 ms** boyunca `PONG` alamazsa bağlantıyı kapatıp yeniden bağlanır.
- Saat farkı tahmini (istemci): `rtt = now − echo_time_us`, `offset = responder_time_us − (echo_time_us + rtt/2)`. En düşük `rtt`'li son örnekler kullanılır. `latency = gösterim_zamanı − (capture_time_us − offset)`.

## 7. Girdi güvenliği (AGENTS.md: girdi asla takılı kalmaz)

Host aşağıdaki durumların **her birinde** release-all uygular: `RELEASE_ALL` mesajı, `BYE`, kontrol bağlantısının kopması, 1.500 ms heartbeat zaman aşımı, protokol hatası, host uygulamasının kapanması. İstemci bir DOWN'u gönderdiyse ilgili UP'u da göndermekle yükümlüdür; göndermeden bağlantı koparsa host release-all ile telafi eder.

## 8. Fixture'lar

`protocol/fixtures/<ad>.hex`: başlık dahil tam çerçeve, alan başına bir satır, yorumda alan adı ve değeri. Dosyalar `protocol/fixtures/gen.py` ile üretilir (`--check` güncelliği doğrular). Swift ve Kotlin testleri her fixture'ı decode edip yorumdaki değerlerle karşılaştırır ve aynı değerlerden aynı baytları encode eder.

Fixture listesi: `hello`, `hello_ack`, `hello_ack_pending`, `stream_config`, `bye`, `pen_hover_to_contact`, `pen_leave`, `pen_eraser`, `key_down`, `key_up_caps`, `pointer_rel`, `pointer_abs`, `scroll`, `pen_gesture`, `release_all`, `ping`, `pong`, `stats`, `keyframe_request`, `video_hello`, `video_frame`, `video_frame_config`.
