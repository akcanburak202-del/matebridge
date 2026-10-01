---
id: T-096
title: Tablet — "Otomatik" bağlantı modu (USB varsa USB, yoksa Wi-Fi; akış sırasında kablo takılınca/çekilince geçiş)
status: in_progress
phase: 4
owner: android-client-dev
depends_on: [T-089]
decisions: []
files:
  - client-android/app/src/main/
  - client-android/app/src/test/
  - backlog/tasks/T-096-client-auto-transport.md
---

## Amaç

Kullanıcı isteği (2026-10-01): USB bağlıyken bile tablet Wi-Fi'de kalıyor. Aktarım (`transport` usb|wifi) yalnızca bağlantı panelinden seçilebiliyor ve panel akış sırasında gizli. Geçiş kolay olmalı.

Mevcut durum:
- Host USB tünellerini (`adb reverse`) kablo takılınca kendisi kuruyor (T-039).
- Host aynı cihazın yeni bağlantısını devralma (takeover) ile kabul ediyor (§3.3).

## Kabul kriterleri

- [ ] Yeni aktarım seçeneği **`auto`**, yeni kurulumlarda ve mevcut kullanıcı için varsayılan. Mevcut `usb`/`wifi` tercihi elle seçilmiş sayılır ve korunur. Panelde üç seçenek: Otomatik / USB / Wi-Fi.
- [ ] `auto` bağlanma sırası:
  - Önce USB (`127.0.0.1` kontrol portu) denenir, kısa zaman aşımıyla (≤500 ms).
  - Bağlanamazsa Wi-Fi (Bonjour/son bilinen adres).
  - Log: `ev=transport_pick mode=auto chosen=usb|wifi reason=…`.
- [ ] `auto` modda Wi-Fi'de akış sürerken USB kullanılabilir olursa tablet oturumu USB'ye taşır:
  - Algılama: USB kablosu/veri bağlantısı ve `127.0.0.1` kontrol portunun açık olması.
  - Önce yeni USB bağlantısıyla devralma, sonra eski Wi-Fi bağlantısı kapanır. Kesinti ≤ ~1–2 s.
  - Yoklama hafif olmalı: kablo durumu yayınına (`ACTION_USB_STATE` / şarj durumu) bağlı ya da en sık 2 s'de bir.
  - Host'ta kimlik doğrulamasız bağlantı yığılmamalı: yoklama yalnızca TCP bağlanabilirliğini dener ve hemen kapatır, ya da gerçek bağlantı denemesine dönüşür. Plan'da hangisi seçildiği açıklanır.
- [ ] `auto` modda USB'de akarken kablo çekilirse bağlantı düşer. Yeniden bağlanma, kullanıcı bir şey yapmadan otomatik olarak Wi-Fi'ye düşer.
- [ ] Girdi güvenliği: geçiş sırasında hiçbir tuş, düğme ya da kalem teması takılı kalmaz. Eski bağlantı kapanırken mevcut release-all/BYE kuralları geçerlidir; yeni oturumda girdi yeniden başlar.
- [ ] Elle `usb` ya da `wifi` seçiliyse bugünkü davranış aynen sürer.
- [ ] `--es transport auto|usb|wifi` deney ek parametresi, kalıcı ayarı ezmeden bir açılış için.
- [ ] Saf mantık (seçim, geçiş karar makinesi, sınırlama) birim testli.
- [ ] `./scripts/check.sh` geçiyor.

## Plan

1. **Saf mantık (`session/AutoTransport.kt`, yeni):**
   - `TransportMode { AUTO, USB, WIFI }`: `parse("auto"|"usb"|"wifi")`, ayardan okurken boş/bilinmeyen → `AUTO`. `Settings.transportMode()/setTransportMode()`. Kayıtlı `usb`/`wifi` korunur (elle seçilmiş sayılır), kayıt yoksa `auto`.
   - `UsbProbe.classify(connect)`: `127.0.0.1:47001`'e ≤500 ms TCP bağlantısı, hemen kapatılır → `OPEN | REFUSED | TIMEOUT | ERROR`, `transport_pick` nedeni.
   - `CableTracker`: `USB_STATE` (`connected`) varsa o; hiç gelmediyse pil `EXTRA_PLUGGED` (≠0 → takılı); ikisi de yoksa `UNKNOWN`.
   - `AutoUsbPolicy`: USB denemesinin zamanı. Kablo çıkıkken hiç denemez. Denemeler arası en az 2 s. Yerel ret (`connect_failed`, port kapalı) sabit 2 s; host'a ulaşıp başarısız olan denemeler (`closed`, BUSY, zaman aşımı, USB'den düşüş) üstel geri çekilme (4 s → en çok 60 s). Başarılı USB oturumunda ya da kablo çıkınca sıfırlanır. Aynı anda tek deneme (asılı kalırsa 10 s sonra serbest).
   - Karar: `auto` + Wi-Fi + oturum kabul edilmiş (`Connected`) → **taşı** (migrate). `auto` + Wi-Fi + bağlı değil (Searching/Idle/Connecting/Disconnected) → **TCP yoklaması**, açıksa USB'ye geç. Onay beklerken ya da `Failed`'da hiçbir şey yapılmaz. `auto` + USB + `Disconnected` → Wi-Fi'ye düş.
2. **Devralma ile taşıma (`SessionMachine` + `SessionController`):** yeni `Event.Migrate(endpoint)` yalnızca ACCEPTED/STREAMING'de kabul edilir.
   - Eski oturum sürerken ikinci bir kontrol bağlantısı (aday, yeni nesil) açılır ve HELLO gönderilir. Aday ACCEPTED alırsa (§3.3 devralma, PAIRED) **terfi** olur:
     - eski video kapanır;
     - eski kontrol **emekliye** ayrılır (BYE yok, girdi yönlendirilmez, kuyruğundaki girdiler yine gider);
     - aday güncel kontrol olur; önce kanıt PING'i, sonra STREAM_PREFS/DISPLAY_RATE/AUDIO_PREFS gönderilir;
     - UI `Connected` kalır (panel açılmaz, son kare ekranda durur).
   - Emekli bağlantı, yeni bağlantıda ilk STREAM_CONFIG gelince kapatılır: host bunu eski oturumu release-all + BYE(SUPERSEDED) ile kapattıktan **sonra** gönderir. Yani sıra "önce devralma, sonra eski kapanır". En geç 2 s'de yine kapanır.
   - Aday başarısız olursa (bağlanamadı, kapandı, BUSY/PENDING/REJECTED, protokol hatası, 3 s zaman aşımı) yalnız aday kapanır; eski oturuma dokunulmaz.
   - Start/Stop/kopma adayı ve emekliyi de kapatır. Her Migrate için tam bir `MigrationResult(ok, reason)` döner.
   - Host yoklamadan kimliksiz bağlantı biriktirmez: akış sırasındaki yoklama **gerçek bağlantı denemesidir**. Port kapalıysa yerel ret olur ve host hiçbir şey görmez; açıksa HELLO gider. Bağlantısız durumda (açılışta seçim ve yeniden tarama) ≤500 ms TCP bağlan-kapat kullanılır. Bu her açılışta ve en sık 2 s'de bir tek bağlantıdır; host bunu 5 s HELLO kuralıyla zaten kapatır.
3. **Girdi güvenliği:**
   - `InputSink` gönderimleri nesille denetlenir (`trySendInput(msg, gen)`, `dropConnection(gen)`). UI, yeni nesli `capture.onSessionReset()` ile **aynı** UI çalıştırmasında öğrenir. Bu yüzden eski modelle (ör. vuruş ortası) üretilmiş bir mesaj yeni bağlantıya gidemez: reddedilir ve model unutulur.
   - Eski bağlantının durumunu host devralmada release-all ile bırakır (§3.3, §7). Bayat nesille gelen bir RELEASE_ALL reddi yeni oturumu düşürmez, çünkü eski bağlantı zaten kapanıyor.
   - Denetleyicide girdi izni artık eylemlerden **sonra** açılır (kanıt PING'i her zaman ilk kayıt); kapanma eskisi gibi hemen olur.
4. **MainActivity:**
   - Panelde Otomatik / USB / Wi-Fi (seçili olan işaretli).
   - `--es transport auto|usb|wifi` bu aktivite için ayarı ezer, kaydetmez; panelden seçim yapılınca biter.
   - `USB_STATE` ve `BATTERY_CHANGED` alıcısı `onStart`/`onStop`'ta kaydedilir; 500 ms'lik `auto` adımı.
   - Son Wi-Fi uç noktası bellekte tutulur; USB düşüşünde doğrudan ona bağlanılır, Bonjour da yeniden başlar.
   - Elle `usb`/`wifi`: bugünkü yol (USB ipucu yalnız elle USB'de).
   - Loglar: `transport_pick mode=… chosen=… reason=…`, `usb_cable state=… src=…`, `transport_migrate ok=… to=… reason=…`, `migrate_start/migrate_switch/retired_close`.
5. **Testler:** `AutoTransportTest` (mod ayrıştırma/varsayılan, yoklama sınıflandırma, kablo, politika zamanlaması/geri çekilme, karar tablosu); `SessionMachineTest`'e taşıma senaryoları (başarı sırası: emekli → terfi → PING ilk; başarısızlıkta eski oturum bozulmaz; zaman aşımı; Start/Stop/kopma sırasında aday kapanır; emekli STREAM_CONFIG'de/2 s'de kapanır); `ConnectModeTest` güncellenir. `./scripts/check.sh`.

## Handoff

