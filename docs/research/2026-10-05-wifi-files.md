# Wi-Fi üzerinden tablet dosyaları — tasarım çalışması (2026-10-05)

**İstek:** tabletteki küçük dosyalara Mac Finder'ından ağ üzerinden erişim (tablet Wi-Fi, Mac Ethernet), görüntü/kalem/sese zarar vermeden. Bugün yalnız USB: 0015 (+0028), PROTOCOL §0x09, T-135..T-139, T-153, T-190. Kod değişmedi; protokolü orkestratör yazar.

## 1. Seçenekler ve öneri

**(A1) Ayrı şifreli dosya bağlantıları, tablet arar — ÖNERİLEN.** Videodaki gibi tablet Mac'e bağlanır; Mac'te yeni bir "dosya dinleyicisi" yalnız kullanıcı Wi-Fi'de "Tablet dosyalarını aç" dediğinde açılır. Tablet 2 boşta, kanıtlanmış dosya bağlantısı hazır tutar (havuz). Mac'te `127.0.0.1` üzerinde yerel vekil dinler; NetFS bunu bağlar. Finder'ın her TCP bağlantısı boştaki bir dosya bağlantısıyla **1:1** eşlenir. İlk şifreli `FILES_DATA` gelince tablet `127.0.0.1:<dav>`'a bağlanır ve baytları iki yönde aktarır; tükenen bağlantının yerine yenisini açar (toplam ≤ 12 = DAV sınırı 8+4). Kapanma da 1:1'dir: bir uç kapanınca öteki kapanır, ayrı mesaj gerekmez. Gerekçeler:
- Tablette LAN'a açık **yeni port yok**; 0015'in "Wi-Fi ağına hiçbir şey açılmaz" ilkesi tablet tarafında korunur.
- Host'un dinleyici/kabul/kanıt altyapısı (`BsdTcpListener`, `admitted`, `acceptVideo`, `videoHello`/`videoProven`) ve istemcinin giden soket kalıbı (`VideoConn`: trafik sınıfı, keepalive, QuickAck) neredeyse aynen kullanılır.
- Host'ta giden bağlantı kodu yok (`BsdTcpSocket.swift` yalnız dinleyici + kabul). A2 bunu sıfırdan yazmayı gerektirir.
- Havuz sayesinde Finder'ın yeni bağlantısı bekleme yapmaz; el sıkışma gidiş-dönüşü havuz dolarken ödenir.

**(A2) Mac arar, tablet LAN'da dinler.** Havuzsuz, daha basit; ama tablette Wi-Fi'ye açık port (HarmonyOS davranışı bilinmiyor) ve Mac'te yeni giden soket kodu. A1 takılırsa yedek.

**(B) Kontrol bağlantısında tünel — hayır.** İndirmeler C→H yönündedir, yani PEN/KEY'in yönü. Aynı TCP akışında kalem olaylarının önüne dosya baytları girer (head-of-line). İstemci kuyruğu 256 KiB/1 s'yi aşınca bağlantıyı koparır (§5); dosyalar oturumu düşürür. Yüklemeler de ses (H→C) ile aynı akışa girer.

**(C) LAN'da TLS WebDAV, sabitlenmiş sertifika — hayır.**
- Finder/webdavfs sertifika sabitlemeyi desteklemez. Kendinden imzalı sertifika ya GUI güven penceresi açar ya yönetici onayıyla anahtar zincirine güven ayarı ister. Mac'in tek ekranı tablet; ajanlar GUI açamaz.
- URL tablet IP'sini taşır (DHCP'de kırılır); port tüm LAN'a açık, Android'de sertifika üretimi zahmetli.

**(D) Video bağlantısında çoğullama — hayır.** Video bağlantısı her ayar değişiminde kapanır (§3.7) ve aktarımları keser. Birden çok Finder bağlantısı için akış kimliği ve akış başına akış denetimi gerekir. **Yeniden kullanılan:** video bağlantısının çerçevesi, kayıt katmanı (`Records.swift` / `RecordSealer`) ve "düz HELLO + nonce + kanıt" deseni. Dinleyici ayrıdır: farklı soket seçenekleri gerekir (BK sınıfı, küçük `NOTSENT_LOWAT`) ve yalnız istek üzerine açılır.

### Güvenlik (A1)
- **Anahtarlar:** `kf_c2h = Expand(prk, "MB1 files c2h" ‖ client_files_nonce ‖ host_files_nonce, 32)`; `kf_h2c` aynı biçimde. Nonce'ların ikisi de tazedir: tablet `FILES_HELLO`'da, host düz `FILES_HELLO_ACK`'te gönderir. Bu yüzden kaydedilmiş bir bağlantının tekrarı iki yönde de etiket doğrulamasında düşer. Videodaki gibi nonce kümesi gerekmez (webdavfs saatte yüzlerce bağlantı açabilir). Sayaç bağlantı ve yön başına 0'dan başlar; anahtar her bağlantıda benzersiz olduğundan GCM nonce'u tekrar etmez.
- **Kanıt:** tablet ilk şifreli kayıt olarak PING gönderir (video §3.5 gibi). Host kanıtlanmamış bağlantıyı havuza almaz. Kanıtsız bağlantı sınırı 2, süre 5 sn. Tablet, host'u ilk `FILES_DATA`'nın etiketinden doğrular.
- **LAN saldırganı:** PAIRED'de `ikm` `pair_key` içerir; aracı anahtar türetemez. Yalnız boyut ve zamanlama sızar. `FILES_HELLO` yalnız güncel `session_id` ile kabul edilir.
- **Tabletteki/Mac'teki başka süreçler:** DAV sunucusu `127.0.0.1`'de Digest jetonu ister (değişmez); Mac vekili yalnız `127.0.0.1`'de dinler, jetonsuz 401. Bugünkü `adb forward` ile aynı duruş.
- **Oturum sonu/uyku:** dosya bağlantıları `session_id`'ye aittir. Oturum bitince (BYE, `HOST_SLEEP`, devralma, 5 sn sessizlik) host `prk`'yi siler ve tüm dosya bağlantılarını kapatır; tablet de `SessionSecrets.wipe` ile aynısını yapar.
- **Yeniden keşif (T-227):** Mac'in adresi değişince tablet yeni adrese yeni oturum açar; yeni `prk` gelir ve dosya bağlantıları yeniden anahtarlanır. Bağlama URL'si yerel vekilin portudur, adres değişiminden etkilenmez.
- **Dinleyici:** "Yalnız USB" profilinde açılmaz; yalnız kontrol bağlantısının eş adresi kabul edilir (savunma katmanı).

## 2. Hız ve gecikme politikası

**Veri (NOTES):**
- Mac Ethernet + tablet Wi-Fi, 30 Mbps hedef: gerçekleşen ~14–18 Mbps; kontrol srtt p95 43 ms (bütçe 40, sınırda); ses 0–1 kesilme / 5 dk; `skip_pct` ~3.
- 100 Mbps hedef: gerçekleşen 66 Mbps; ağ p99 26→40 ms, 361 ms sıçrama, atılan kare 119→209; **kullanıcı donma gördü** (2026-10-05 ~20:35).
- Tam ekran değişiminde kare başına 100–450 KB patlama, video cwnd sınırsız (13:20, 0023).
- Ham bağlantı ~410 Mbps. Sorun kapasite değil, patlamada kablosuz kuyruk.

**Kural:** toplam ortalama ~48 Mbps'in altında kalsın (donan 66 Mbps'in ~¾'ü). Buradan
`files_cap = clamp((48 − video_hedef_Mbps) / 8, 0,5, 3,0) MB/s`:

| Video hedefi | Dosya tavanı |
|---|---|
| 30 Mbps (Günlük 60) | 2,25 MB/s |
| 15 Mbps | 3 MB/s |
| 60 Mbps (Oyun 120) | 0,5 MB/s |

İki taraf da hedefi `STREAM_CONFIG.bitrate_kbps`'ten bilir; tel değişikliği gerekmez. Değerler cihaz ölçümüyle doğrulanır (§5, bütçeler ölçümden önce yazılır):
- kontrol srtt p95 ≤ 45 ms;
- ses ≤ 1 kesilme / 5 dk;
- `skip_pct` dosyasız temelden en çok +1 puan;
- cap_dec p95 en çok +10 ms.

- **Uygulama noktası:**
  - İndirme (C→H): tabletteki ortak `TokenBucket`; tavan çalışırken değişebilmeli.
  - Yükleme (H→C, videoyla aynı AP→tablet kuyruğu): **Mac vekili gönderirken** hızı sınırlar. Alıcıda pencereyle kısma patlamalı olur.
  - Wi-Fi'de patlama payı 256 KiB yerine 64 KiB, `FILES_DATA` ≤ 16 KiB, aktarım tamponu 16 KiB.
  - Mac dosya soketi: `SO_SNDBUF` ~128 KiB ve `TCP_NOTSENT_LOWAT` 16 KiB.
- **Video yokken:** sunucu yalnız akan, ön plandaki oturumda çalışır; "videosuz" durum pratikte yok. Durağan ekranda artış ikinci adımda AIMD ile: tablet PING rtt'si / Mac `tcp_info` srtt (`TcpInfoLog`) düşükse +0,25 MB/s/sn (en çok 6), taban +25 ms aşılırsa ya da `KEYFRAME_REQUEST(FRAMES_DROPPED)` görülürse yarıya.
- **USB:** `adb forward` yolu ve 20 MB/s tavan **aynen** kalır.
- **Öncelik:**
  - Mac dosya soketi `NET_SERVICE_TYPE_BK` (CS1, `BsdTcpOptions.serviceClass`).
  - Tablet `trafficClass = 0x20` (`WifiKnobs.kt:38` `TrafficClass.trySet`).
  - Bu en iyi çabadır: T-127'de `tos_ctl 0xB8` ölçülebilir fark yaratmadı. Asıl güvence tavandır.
- **Küçük isteklerin gecikmesi:**
  1. Kova sırası: 2 MB/s'de 8 bağlantı × 64 KiB toplu borç ≈ 250 ms. Küçük bir PROPFIND yanıtı bu borcun arkasında bekler (`TokenBucket.kt:24`). Çare: ≤ 32 KiB'lık istek/yanıtlar için ayrı küçük kova (~256 KB/s), toplu işin önüne geçer.
  2. Havuz önceden ısıtılır: Finder bağlantısı ek gidiş-dönüş beklemez.
  3. `._*` ve `.DS_Store` zaten bellekte (`MetaStore`, `DavHandler.kt:477`), depolamaya yazılmaz. Ek olarak bilinen macOS yoklamaları depolamaya dokunmadan hızlı 404 alır: `.hidden`, `.localized`, `.Trashes`, `.Spotlight-V100`, `.fseventsd`, `.VolumeIcon.icns`, `.TemporaryItems`.
  4. İsteğe bağlı PROPFIND önbelleği (`DavHandler.kt:143`): Depth 1, mtime + 2 sn TTL, yazmada geçersiz, 64 dizin / 2 MB; yalnız ölçüm FUSE `stat` maliyeti gösterirse.
  5. **En büyük risk (T-138):** webdavfs açılan dosyanın tamamını indirir. Finder video önizlemeleri GB'larca veri çeker ve webdavfs'in 5 iş parçacığını tutar. 2 MB/s'de bu dakikalar sürer, birimi kilitler. Çare: Wi-Fi'de `wifi_max_file`'dan (öneri 64 MB) büyük dosyaya Range'siz GET **reddedilir**. PROPFIND onları yine listeler; tabletin durum satırı "büyük dosyalar için USB" der. webdavfs'in red karşısındaki davranışı önce `tools/dav-repro` ile (`MB_DAV_RATE` 2 MB/s) tablet olmadan doğrulanır.
- **Sınırlı kuyruklar:**
  - vekil: bağlantı başına yön başına 64 KiB, en çok 12 bağlantı;
  - havuz: en çok 2 boşta;
  - kanıtsız bağlantı: en çok 2;
  - tavana takılan yazma kovada bekler, kuyruk büyümez.

## 3. Protokol etkisi (yalnız tarif; yazan orkestratör)

- **`HELLO.capabilities` bit12 `FILES_NET`:** istemci dosya bağlantısını ve aşağıdaki mesajları işler (bit11 = `FULL_CHROMA`, T-257).
- **`FILES_INFO.state = 2` STANDBY:** paylaşım açık ve izinli, ağ isteği bekleniyor. Bugünkü kural gereği eski host bunu OFF sayar. Port/jeton boştur.
- **0x0A `FILES_NET` (H→C, kontrol), yalnız bit12 ile:** `state u8` (0 CLOSE, 1 OPEN), `port u16` (host dosya dinleyicisi), `pool u8` (2), `max u8` (12).
  - Kullanıcı Wi-Fi'de menüden açınca OPEN gider. Tablet sunucuyu başlatır, `FILES_INFO READY` gönderir, havuzu açar.
  - Çıkarma ya da oturum sonunda CLOSE gider. Tablet havuzu kapatır ve STANDBY'a döner.
- **Dosya bağlantısı (§2 tablosuna üçüncü satır, aralık 0x50–0x5F):**
  - 0x50 `FILES_HELLO` (C→H, düz): `protocol_version u16`, `session_id u32`, `client_files_nonce [16]`.
  - 0x51 `FILES_HELLO_ACK` (H→C, düz): `status u8` (0 OK, 1 REJECTED), `host_files_nonce [16]`.
  - Sonrası §9 kayıtlarıdır; ilk C→H kaydı PING (kanıt).
  - 0x52 `FILES_DATA` (iki yön): `bytes` (opak HTTP baytları), en büyük payload 65 536.
- **§9:** `"MB1 files c2h"`, `"MB1 files h2c"` + iki nonce. Host `prk`'yi zaten oturum boyunca tutar; istemci de tutar (`SessionSecrets`).
- **Fixture'lar:**
  - `files_info_standby`, `files_net_open`, `files_net_close`, `files_hello`, `files_hello_ack`, `files_data`, `invalid_files_hello_short`;
  - `crypto_vectors.json`'a sabit nonce'larla dosya anahtarları + iki yönde birer kayıt.

## 4. Değişiklikler (dosya:satır)

**Host (Core):**
- `Protocol/FilesMessages.swift:14`: STANDBY, `FilesNet`, `FilesHello(Ack)`, `FilesData`.
- `Message.swift:11/40/73/181`: yeni mesaj durumları.
- `Crypto/KeySchedule.swift:100`: `videoKeys` yanına `filesKeys(client:host:)`.
- `Session/SessionMachine.swift:432–470`: `videoHello`/`videoProven` deseninde `filesHello`/`filesProven`. Ya da yalnız etkin oturumun anahtar programını veren dar bir sorgu.
- `Files/TabletFilesPlanner.swift`:
  - `Forward` (:149–157) "upstream" olur: `.adbForward` / `.netProxy`.
  - `transport == .usb` kapıları (:225, :480, :554) ağ dalını kazanır.
  - `installForward` (:51) yanına `startProxy`/`stopProxy` gelir.
  - Teardown sırası (önce bağlantıyı ayır, sonra upstream'i kaldır) aynen kullanılır. Yeniden bağlamada otomatik bağlama (`autoMountArmed`, T-206) aynen işler.
- `Files/WebDavMount.swift:7`: vekil portu 47012. 47010 ile çakışmaz; `isOurs` port alır.
- Yeni saf `FilesRateCap` (Kotlin `TokenBucket`'ın Swift karşılığı + formül).

**Host (App):**
- `Session/SessionServer.swift`:
  - `startVideoListener` (:473) kalıbıyla istek üzerine `startFilesListener`;
  - `admitted` (:970) ve `acceptVideo` (:983) / `receiveVideoProof` (:1112) karşılıkları;
  - eş adres süzgeci.
- Yeni `Files/FilesNetProxy.swift`: yerel dinleyici `.loopbackV4Mapped`, havuz eşleme, kayıt mühürleme, gönderici hız sınırı.
- `Files/TabletFilesBridge.swift:198` `execute`: yeni eylemler. NetFS bağlama (:303, `AllowLoopback`, `SoftMount`) aynen kalır.
- `MateBridgeApp/main.swift:178–210, 369–374`: "Tablet dosyalarını aç (Wi-Fi)" ve bit hızının vekile iletimi.

**İstemci:**
- `protocol/Messages.kt`, `Codec.kt`: yeni mesajlar.
- `security/Handshake.kt:33`: `filesKeys`; `Crypto.kt:143`: KDF.
- `session/SessionMachine.kt` ve `SessionController.kt`: `FILES_NET` dağıtımı. `VideoConn` (:876–914) kalıbında yeni `files/FilesTunnel.kt` (havuz, ilk veride DAV'a bağlanma, aktarma, keepalive `:1144`).
- `files/FilesSwitch.kt:17`: `transport == USB || (WIFI && netOpen && wifiShare)`. Durum metinleri :41–43.
- `files/FilesLifecycle.kt:97`: STANDBY yayını.
- `files/FilesConfig.kt:46–49`: Wi-Fi profili.
- `files/TokenBucket.kt:24`: `setRate` + küçük şerit.
- `files/DavHandler.kt`: büyük dosya koruması, hızlı 404, önbellek.
- `MainActivity.kt:592` ve settings: "Wi-Fi üzerinden de paylaş". Cihaz testine kadar varsayılan kapalı.

**Hata durumları:**
- **Kopyalama sırasında Wi-Fi düşerse:**
  - host 5 sn sessizlikte oturumu kapatır, bağlantıyı ayırır (`SoftMount`: Finder hata verir, asılı kalmaz), vekili kapatır;
  - yarım PUT'un geçici dosyası zaten silinir (`DavHandler.kt:248–261`);
  - yeniden bağlanınca, kullanıcı çıkarmadıysa birim otomatik bağlanır; kopya yeniden başlatılır.
- **Yarı açık soket:** iki uçta TCP keepalive (T-218 gibi) + DAV'ın 30 sn zaman aşımları.
- **Çıkarma:** `didUnmount` → bağlama niyeti biter (T-206) → `FILES_NET(CLOSE)`.
- **Mac uykusu:** `BYE(HOST_SLEEP)` → `sessionEnded` → ayırma. Uyanınca yeni oturum, STANDBY, niyet sürüyorsa yeniden bağlanır.
- **Tablet arka plana geçerse:** OFF → ayırma.
- **USB↔Wi-Fi geçişi:** upstream değişir, port farklı (47010/47012) → birim yeniden bağlanır (bilinen sınırlama; ileride USB de vekilden geçerse URL sabit kalır).

## 5. Efor, kartlar, sıralama

| Kart | İş | Ajan-gün | Bağımlılık / çakışma |
|---|---|---|---|
| P (orkestratör) | Karar 0035 + PROTOCOL + fixture + kripto vektörleri | 0,5–1 | T-257 birleşince (bit11, fixture listesi ve §2'de metin çakışması) |
| C1 istemci `files/` | `TokenBucket` setRate + küçük şerit, Wi-Fi profili, büyük dosya koruması, hızlı 404; `dav-repro` ile 2 MB/s ölçüm | 1–1,5 | **Hemen başlayabilir**: T-259'un `files:` listesinde `files/` yok |
| H1 host Core | Kodekler, `filesKeys`, planner ağ dalı, `FilesRateCap`, testler | 1,5 | P + **T-258'den sonra** (T-258 `MateBridgeCore/`'un tamamını tutuyor; `Message.swift` ve `SessionMachine` çakışır) |
| H2 host App | Dosya dinleyicisi + kanıt, `FilesNetProxy`, menü | 1,5 | H1; T-258 `MateBridgeHost/Session/` (`SessionServer`) ile çakışır |
| C2 istemci oturum | Kodekler, `filesKeys`, `FILES_NET`, `FilesTunnel`, STANDBY, ayar | 2 | P + **T-259'dan sonra** (`protocol/`, `session/`, `MainActivity.kt` ortak) |
| D cihaz | Bütçeli ölçüm (kullanıcıyla) + Codex `--high` (güvenlik/protokol) | 0,5–1 | H2 + C2 |
| (ops.) A | AIMD uyarlama, PROPFIND önbelleği | 1 | D sonrası, ölçüm gösterirse |

**Toplam:** ~7–8,5 ajan-günü. 4:4:4 bittikten sonraki kritik yol ~4 gün: H1→H2 ile C2 paralel, ardından D.

**Önerilen sıra:**
1. T-257 birleşir.
2. P yazılır; C1 aynı anda paralel başlar.
3. T-258/T-259 birleşince H1 ve C2.
4. H2.
5. D.

Orkestratör C1 için `files:` listesini `client-android/.../files/`, testleri ve `tools/dav-repro/` ile sınırlamalı.

**Açık sorular (kullanıcıya):**
- Wi-Fi'de en büyük dosya sınırı (64 MB önerisi) uygun mu?
- "Wi-Fi üzerinden de paylaş" ayarı varsayılan açık mı olsun, kapalı mı?
