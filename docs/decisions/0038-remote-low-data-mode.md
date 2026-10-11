# 0038 — Uzaktan bağlantı: "Uzaktan bağlan" düğmesi, en az veri profili, AAC ses, uzaktan eşleşme yok

- **Durum:** kabul (2026-10-11)
- **Tarih:** 2026-10-11

## Bağlam

Kullanıcı Mac'e evin dışından da (mobil veri, başka Wi-Fi) ulaşmak istiyor. Bu yolda yapacağı iş az: masaüstüne göz atmak ve terminalde ajanla kod yazmak. Kalem ve oyun yok. Ses çoğunlukla kapalı, gerekince açılır. İstek iki şey: **mümkün olan en az veri** ve **kimse verilere ulaşmasın**. Ağ yolu Tailscale (WireGuard); Mac internete port açmaz. PLAN'da "internet erişimi" ertelenenler arasındaydı; bu karar onu dar bir kapsamla açar.

Kullanıcı kararları (2026-10-11):
- **Otomatik geçiş yok.** Giriş ekranında ayrı bir düğme olur, kullanıcı bilerek seçer. Bunun dışında MateBridge bugünkü gibi çalışır.
- Uzak yolda ses varsayılan kapalı; açılınca AAC.
- SSH şimdilik yok.

Keşif bulguları (2026-10-11 tarama):
- Durgun ekranda host zaten kare göndermiyor (ölçülen 0,2–1,4 KB/s, `docs/research/2026-10-08-baseline.md`). Asıl maliyet: hareketli içerik, sabit ekran netleştirme trenleri (ağ yolunda tren başına 256 KB'a kadar), keyframe'ler ve saniyede ~9 küçük kontrol paketi (VPN başlıklarıyla ~2–3 KB/s, saatte ~10 MB).
- Protokol fps olarak yalnız 60/120/144, bit hızı olarak en az 5 Mbps kabul ediyor. Ses yalnız PCM (1,5 Mbps) ve `AUDIO_FRAME.frame_count` en çok 960.
- Yavaş hatta istemci keyframe beklerken her 500 ms'de `STARTUP` isteği yineliyor; keyframe 500 ms'de ulaşamıyorsa döngüye girer.
- Mobil hatta 1,5–3 sn takılmalar bugün oturumu düşürür (istemci PONG 3 sn, host kapanış 5 sn).
- Elle adresle (Tailscale `100.x` ya da MagicDNS adı) bağlanmak kod değişikliği olmadan çalışır; Bonjour gerekmez.

## Karar

### 1. Giriş ekranında "Uzaktan bağlan"
- Bağlantı ekranına ayrı bir **"Uzaktan bağlan"** düğmesi eklenir. Uzak adres (Tailscale IPv4 ya da MagicDNS adı, port isteğe bağlı, varsayılan 47001) elle adresten **ayrı** saklanır. İlk kullanımda sorulur, sonra düzenlenebilir.
- Bu düğmeyle kurulan oturum **uzak oturumdur**. Diğer bütün yollar (USB, Bonjour, elle adres, otomatik yeniden bağlanma) bugünkü gibi çalışır ve asla uzak profili seçmez.
- Uzak oturum koparsa istemci aynı uzak adrese yeniden bağlanır (normal geri çekilme kuralları). Uygulama yeniden açılınca uzak adrese kendiliğinden bağlanmaz.
- Uzak oturumda Wake-on-LAN gönderilmez.

### 2. Uzak profil (istemcinin seçtiği akış ayarları)
Uzak oturum kendi ayarlarıyla çalışır; kullanıcının mod ve görüntü ayarlarına dokunmaz, oturum bitince hiçbir şey değişmiş olmaz.
- **Görüntü:** 0029 yolu ile 1x sanal ekran **1400×920** (`display_*`), **15 fps**, 4:2:0, SDR. Mod seçimi (Günlük/Çizim/Oyun) ve Ctrl+Shift+7 uzak oturumda etkisizdir; panel "Uzak (Tasarruf)" gösterir.
- **Bit hızı:** seçenekler **0,5 / 1 / 2 Mbps**, varsayılan **1 Mbps**; uzak oturum için ayrı hatırlanır.
- **Yerel imleç** (0036) açık: imleç hareketi video karesi üretmez ve 15 fps'te de akıcıdır.
- **Ses:** uzak oturum için ayrı bir ses ayarı, varsayılan **kapalı**. Açılınca istemci AAC ister (§4).
- **Tablet dosyaları** (0035) uzak oturumda kapalı: istemci `FILES_INFO` durumunu OFF bildirir.
- Kalem ve parmak girdisi bugünkü gibi çalışır (engellenmez); profil onlar için ayar yapmaz.

### 3. Protokol: STREAM_PREFS
- `fps`: `15` ve `30` geçerli değerlere eklenir. Eski host bunları 60 sayar.
- `bitrate_kbps` sıkıştırma aralığı `500`–`150000` olur (alt sınır 5000'den iner). Eski host 5000'e yükseltir.
- **Üçüncü isteğe bağlı grup** (payload 16 bayt): `link` u8 (`0` normal, `1` uzak/en az veri; diğer değerler `0` sayılır) + `reserved` u8. İstemci grubu yalnız `link ≠ 0` iken yazar; o zaman önceki iki grup da (sıfır olabilir) yazılır. 15 bayt kısa payload'dur (protokol hatası).
- Host `link = 1` iken (yalnız bu oturum için):
  - kontrol bağlantısına PING'i **2 sn**'de bir gönderir;
  - heartbeat kapanışı **15 sn** olur. **1,5 sn release-all kuralı değişmez** (girdi güvenliği);
  - `CURSOR_STATE` canlılık aralığı **2 sn** olur;
  - sabit ekran netleştirme treni bütçesi hedef bit hızının **250 ms**'si kadardır (en az 16 KB);
  - video soketi düşük su işareti hedef bit hızının **250 ms**'si kadardır (en az 16 KB);
  - `FILES_NET OPEN` göndermez;
  - bu tercihi cihaz başına hatırlanan tercihe (T-049) **yazmaz**: evdeki bir sonraki bağlantı uzak ayarlarla açılmaz.

### 4. Protokol: AAC ses
- HELLO `capabilities` bit14 `AUDIO_AAC`: istemci AAC-LC 48 kHz stereo çözebilir.
- `AUDIO_PREFS` ikinci bayt (eski `reserved`) `codec` olur: `0` PCM, `1` AAC. Diğer değerler `0` sayılır. Host AAC'yi yalnız bit14 ve `codec = 1` iken kullanır; aksi halde PCM. Eski host alanı yok sayar ve PCM gönderir; istemci PCM'i her zaman çalabilmelidir.
- `AUDIO_CONFIG.format = 2` AAC_LC: 48 kHz, 2 kanal, `frames_per_packet = 1024`. Her `AUDIO_FRAME` tam bir ham AAC erişim birimi (ADTS yok) taşır, `frame_count = 1024`. Kodek yapılandırması (AudioSpecificConfig) `sample_rate` ve `channels`'tan türetilir, telde taşınmaz.
- `AUDIO_FRAME.frame_count` sınırı **1–1024** olur (dışı protokol hatası). PCM için `data_len = frame_count × 4` kuralı sürer.
- Hedef bit hızı **96 kbps** (host). Kodlama Mac'te `AudioConverter`, çözme tablette `MediaCodec`: yeni bağımlılık yok.
- Sessizlik kapısı (T-279) ve 60 sn duraklatma (T-287) AAC'de de geçerlidir.

### 5. Güvenlik
- **Uzaktan eşleşme yok.** Host yeni eşleşmeyi (PAIRING) yalnız loopback (USB) eşinden ya da Mac'in fiziksel bir arayüzünün (`en*`) doğrudan bağlı alt ağındaki eşten kabul eder. Diğer her eşe (Tailscale `utun`, `100.64.0.0/10`, yönlendirilmiş adresler) PAIRING gerekirse şifresiz `HELLO_ACK(REJECTED, NONE)` gönderir, Mac'te onay penceresi **açılmaz**, `ev=pairing_refused reason=remote` loglanır. PAIRED bağlantılar her yerden kabul edilir; anahtarı olmayan biri oturum kuramaz. Bu kural `link`'e değil eş adrese bağlıdır (istemcinin beyanına güvenilmez). Tel biçimi değişmez.
- İstemci uzak oturumda REJECTED alırsa "Yeni eşleşme yalnız ev ağında ya da USB ile yapılabilir" gösterir.
- Mac internete port açmaz; erişim yalnız Tailscale ağı içinden. Tailscale hesabının güvenliği (iki adımlı doğrulama, Tailnet Lock, cihaz kaldırma) kullanıcının sorumluluğundadır ve koddan bağımsızdır.

### 6. İstemci zamanlamaları (uzak oturum)
- PING: herhangi bir girdi tutuluyorken (tuş, düğme, kalem, açık hareket) ya da son girdiden sonraki 2 sn içinde **500 ms**; aksi halde **2 sn**. Böylece tutulan girdi varken 1,5 sn release-all kuralı yanlış tetiklenmez; boştayken release-all'ın bırakacak bir şeyi yoktur.
- PONG zaman aşımı **10 sn**. `STATS` aralığı **5 sn** (`interval_ms = 5000`). Yerel imleç zaman aşımı **5 sn**.
- Oynatma başlangıç tamponu uzak oturumda ses için en az 100 ms.

### 7. Tüm oturumlar için düzeltme
- Keyframe beklerken `STARTUP` yinelemesi 500 ms'den başlar ve her seferinde iki katına çıkar, en çok **4 sn** (keyframe gelince sıfırlanır). Yerel ağda keyframe ilk 500 ms içinde geldiği için pratikte değişiklik yok.

## Sonuçlar

- **Kazanılan:** evin dışından, bilerek seçilen, ayrı ayarlı bir yol. Kaba tahmin: durgun ekranda saatte ~3–4 MB (kontrol trafiği), sürekli tam ekran harekette üst sınır 1 Mbps'te saatte ~450 MB; terminal akışı bunun çok altında. Gerçek değerler kullanırken ölçülür.
- **Kaybedilen / bedel:** uzak oturumda Mac sanal ekranı 1400×920'ye iner; pencereler yeniden dizilir ve eve dönünce (2800×1840 HiDPI) macOS her pencereyi eski yerine koymayabilir. 15 fps'te kaydırma kesik görünür. AAC sese ~50 ms gecikme ekler.
- **Protokol:** PROTOCOL.md §4 (STREAM_PREFS, AUDIO_*), §6; fixture'lar `stream_prefs_remote`, `invalid_stream_prefs_link_partial`, `audio_prefs_aac`, `audio_config_aac`, `audio_frame_aac`, `invalid_audio_frame_count`.
- **Kartlar:** T-336 (protokol, orkestratör), T-337 (host protokol + uzak profil), T-338 (host uzaktan eşleşme yasağı), T-339 (istemci protokol + "Uzaktan bağlan" + uzak profil + keyframe geri çekilmesi), T-340 (host AAC), T-341 (istemci AAC). Entegrasyon dalı `task/0038-remote-integration`.
- **Tekrar düşünülür:** uzak yolda kalem ya da daha yüksek çözünürlük istenirse; TCP yerine paket kaybına dayanıklı bir taşıma gerekirse; SSH/Ekran Paylaşımı ikinci yol olarak açılırsa.

## Ek (2026-10-11): uygulama ayrıntıları (orkestratör kararları, tasarım kontrolünden)

1. **Eş sınıflandırma (§5):** kontrol bağlantısının `getpeername` adresi şu durumlarda "yerel" sayılır: loopback (`127.0.0.0/8`, `::1`, IPv4-mapped dahil) ya da `getifaddrs`'ta adı `en` ile başlayan, `IFF_UP` bir arayüzün IPv4 `adres & maske` alt ağında olan IPv4 eş; IPv6 için aynı arayüzlerin önek eşleşmesi (link-local `fe80::/10` yalnız kapsam arayüzü `en*` ise). `100.64.0.0/10` her zaman uzak. Belirlenemeyen her durum **uzak** sayılır (reddet). Loopback kabul edilir, çünkü USB yolu (`adb reverse`) loopback'tir; bu yüzden MateBridge portlarına `tailscale serve`/`funnel` ya da SSH tüneliyle yönlendirme yapılmamalıdır (RECOVERY/README notu).
2. **"Yalnız USB" modu** (0027) değişmez: o modda uzak bağlantı yoktur. Varsayılan dinleyici bütün arayüzlerde (`utun` dahil) dinler; ek ayar gerekmez.
3. **Ekran boyutu ve devralma:** sanal ekran her zaman STREAM_PREFS ile değişir; ayrı bir yol yoktur. Uzak tercih hatırlanmadığı için (§3) uzak oturum bittikten sonra gelen normal oturum hatırlanan normal tercihle (2800×1840 HiDPI) açılır; ekranın bırakılması bugünkü kurallarla olur (0020). Devralma bugünkü kuralla işler; yeni oturumun STREAM_PREFS'i ekranı belirler. Eşleşme reddi oturum kurulmadan olur, ekrana dokunmaz.
4. **Mevcut uyarlamalar değişmez:** T-293 kesici ve T-294 geri çekilme yerel olayları ölçer, aynen kalır. `MATEBRIDGE_WIFI_ADAPT` varsayılan kapalı ve tabanı 12 Mbps olduğundan uzak oturumu etkilemez. Keyframe aralığı (300 sn) ve `DataRateLimits` (1 sn'de 2× ortalama) aynen kalır; keyframe boyutu bu sınırla bit hızına bağlı kalır.
5. **İstemci ağ değişimi:** uzak oturumda otomatik USB/Wi-Fi geçişi ve ağ geri çağrıları oturumu düşürmemeli ya da başka yola geçirmemeli (VPN/mobil veri etkin ağ olabilir). Kart bunu denetler.
6. **Reddedilen ilk uzak bağlantı:** istemci mesajı gösterir, giriş ekranında kalır, yeniden denemez. Uzak adres alanı: IPv4 ya da DNS adı (sondaki nokta atılır), isteğe bağlı `:port`; IPv6 desteklenmez (bugünkü `Endpoint` gibi).
7. **`link`'in ömrü:** oturum başına, son uygulanan STREAM_PREFS'teki değer geçerlidir. STREAM_PREFS gelene kadar normal zamanlamalar geçerlidir. İstemci uzak oturumda `link = 1`'i her STREAM_PREFS'te gönderir.
