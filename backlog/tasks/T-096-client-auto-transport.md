---
id: T-096
title: Tablet — "Otomatik" bağlantı modu (USB varsa USB, yoksa Wi-Fi; akış sırasında kablo takılınca/çekilince geçiş)
status: review
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

- [x] Yeni aktarım seçeneği **`auto`**, yeni kurulumlarda ve mevcut kullanıcı için varsayılan. Mevcut `usb`/`wifi` tercihi elle seçilmiş sayılır ve korunur. Panelde üç seçenek: Otomatik / USB / Wi-Fi.
- [x] `auto` bağlanma sırası:
  - Önce USB (`127.0.0.1` kontrol portu) denenir, kısa zaman aşımıyla (≤500 ms).
  - Bağlanamazsa Wi-Fi (Bonjour/son bilinen adres).
  - Log: `ev=transport_pick mode=auto chosen=usb|wifi reason=…`.
- [ ] `auto` modda Wi-Fi'de akış sürerken USB kullanılabilir olursa tablet oturumu USB'ye taşır:
  - Algılama: USB kablosu/veri bağlantısı ve `127.0.0.1` kontrol portunun açık olması.
  - Önce yeni USB bağlantısıyla devralma, sonra eski Wi-Fi bağlantısı kapanır. Kesinti ≤ ~1–2 s.
  - Yoklama hafif olmalı: kablo durumu yayınına (`ACTION_USB_STATE` / şarj durumu) bağlı ya da en sık 2 s'de bir.
  - Host'ta kimlik doğrulamasız bağlantı yığılmamalı: yoklama yalnızca TCP bağlanabilirliğini dener ve hemen kapatır, ya da gerçek bağlantı denemesine dönüşür. Plan'da hangisi seçildiği açıklanır.
- [ ] `auto` modda USB'de akarken kablo çekilirse bağlantı düşer. Yeniden bağlanma, kullanıcı bir şey yapmadan otomatik olarak Wi-Fi'ye düşer.
- [x] Girdi güvenliği: geçiş sırasında hiçbir tuş, düğme ya da kalem teması takılı kalmaz. Eski bağlantı kapanırken mevcut release-all/BYE kuralları geçerlidir; yeni oturumda girdi yeniden başlar.
- [x] Elle `usb` ya da `wifi` seçiliyse bugünkü davranış aynen sürer.
- [x] `--es transport auto|usb|wifi` deney ek parametresi, kalıcı ayarı ezmeden bir açılış için.
- [x] Saf mantık (seçim, geçiş karar makinesi, sınırlama) birim testli.
- [x] `./scripts/check.sh` geçiyor.

## Plan

1. **Saf mantık (`session/AutoTransport.kt`, yeni):**
   - `TransportMode { AUTO, USB, WIFI }`: `parse("auto"|"usb"|"wifi")`, ayardan okurken boş/bilinmeyen → `AUTO`. `Settings.transportMode()/setTransportMode()`. Kayıtlı `usb`/`wifi` korunur (elle seçilmiş sayılır), kayıt yoksa `auto`.
   - `UsbProbe.classify(connect)`: `127.0.0.1:47001`'e ≤500 ms TCP bağlantısı, hemen kapatılır → `OPEN | REFUSED | TIMEOUT | ERROR`, `transport_pick` nedeni.
   - `CableTracker`: `USB_STATE` (`connected`) varsa o; hiç gelmediyse pil `EXTRA_PLUGGED` (≠0 → takılı); ikisi de yoksa `UNKNOWN`.
   - `AutoUsbPolicy`: USB denemesinin zamanı. Kablo çıkıkken hiç denemez. Denemeler arası en az 2 s. Yerel ret (`connect_failed`, port kapalı) ilk 15 denemede 2 s, sonra 10 s (uygularken eklendi: duvar şarj cihazında sonsuz 2 s'lik log gürültüsü olmasın; kablo değişince yine 2 s); host'a ulaşıp başarısız olan denemeler (`closed`, BUSY, zaman aşımı, USB'den düşüş) üstel geri çekilme (4 s → en çok 60 s). Başarılı USB oturumunda ya da kablo çıkınca sıfırlanır. Aynı anda tek deneme (asılı kalırsa 10 s sonra serbest).
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
5. **Testler:** `AutoTransportTest` (mod ayrıştırma/varsayılan, yoklama sınıflandırma, kablo, politika zamanlaması/geri çekilme, karar tablosu); `MigrationTest` (yeni dosya) taşıma senaryoları (başarı sırası: emekli → terfi → PING ilk; başarısızlıkta eski oturum bozulmaz; zaman aşımı; Start/Stop/kopma sırasında aday kapanır; emekli STREAM_CONFIG'de/2 s'de kapanır); `ConnectModeTest` güncellenir. `./scripts/check.sh`.

## Handoff

- **Commit:** `83b5065` (uygulama). Plan: `005fe35`. Dal: `task/T-096-auto-transport` (`main` 8f84c09 üstünde).
- **check.sh:** ALL OK.

**Dokunulan dosyalar**
- `session/AutoTransport.kt` (yeni): `TransportMode`, `UsbProbe`/`ProbeResult`, `CableTracker`, `AutoUsbPolicy`.
- `session/SessionMachine.kt`: `Event.Migrate`; aday/emekli eylemleri; `MigrationResult`.
- `session/SessionController.kt`: `migrate()`, `trySendInput(msg, gen)`, `dropConnection(gen)`; aday/emekli bağlantılar; ayrı aday kapanma kutusu; girdi izni eylemlerden sonra açılıyor; PONG yalnız güncel nesilden.
- `session/Settings.kt`: `transportMode()`/`setTransportMode()`; eski `transport()` kaldırıldı.
- `session/ConnectMode.kt`: `showUsbHint(TransportMode, …)`.
- `MainActivity.kt`, `res/layout/activity_main.xml` (`connect_auto` düğmesi), `res/values/strings.xml` (`connect_auto`; USB/Wi-Fi düğmeleri "Yalnız USB"/"Yalnız Wi-Fi").
- Testler: `test/.../session/AutoTransportTest.kt` (yeni, 10 test), `test/.../session/MigrationTest.kt` (yeni, 8 test), `ConnectModeTest.kt` (güncellendi).

**Davranış**
- **Mod:** Kayıt yoksa `auto`. Kayıtlı `usb`/`wifi` korunur (kart gereği). **Dikkat:** tablette daha önce "Wi-Fi ile bağlan"a basılmışsa kayıt `wifi`'dir ve Otomatik'e geçmez. Panelden bir kez "Otomatik"e basılmalı ya da `--es transport auto` ile açılmalı.
  - Panel düğmeleri: "Otomatik (USB varsa USB, yoksa Wi-Fi)", "Yalnız USB", "Yalnız Wi-Fi". Seçili olanın sonunda "(seçili)" yazar.
  - İstatistik katmanında `Bağlantı: USB (otomatik)`.
- **Açılış (`auto`):** `127.0.0.1:47001`'e 500 ms'lik TCP bağlan-kapat, ayrı iş parçacığında.
  - `MB/session ev=transport_pick mode=auto chosen=usb reason=usb_open` ya da `chosen=wifi reason=usb_refused|usb_timeout|usb_error`.
  - Wi-Fi seçilince Bonjour başlar; bu aktivitede daha önce kullanılan Wi-Fi adresi varsa ona da hemen bağlanılır.
  - Elle modlarda `transport_pick mode=usb|wifi chosen=… reason=manual`.
- **Akış sırasında Wi-Fi → USB (`auto`):**
  - Tetik: 500 ms'lik adım, denemeler en az 2 s arayla; kablo bilinen şekilde çıkıkken hiç deneme yok.
  - Deneme `127.0.0.1:47001`'e gerçek bir aday bağlantıdır (HELLO). `adb reverse` yoksa yerel ret olur (`transport_migrate ok=0 reason=connect_failed`), host hiçbir şey görmez.
  - Başarı log sırası: `migrate_request` → `migrate_start cand_gen=N` → `hello_sent … cand_gen=N` → `hello_ack status=0 …` → `migrate_switch … transport=usb` → `transport_migrate ok=1 to=usb reason=ok` → `transport_pick mode=auto chosen=usb reason=migrated` → `stream_config …` → `retired_close old_gen=M` → `video_open …`.
  - Panel açılmaz, son kare yeni akış gelene kadar ekranda kalır.
- **USB → Wi-Fi (`auto`):** USB'deyken UI `Disconnected` olursa (kablo çekildi, host kapandı, ilk USB bağlantısı başarısız) `transport_pick mode=auto chosen=wifi reason=usb_lost` yazılır.
  - Son Wi-Fi adresi biliniyorsa doğrudan ona bağlanılır. Bilinmiyorsa (açılış USB'yle olduysa) oturum durdurulur ve Bonjour bağlar.
  - Bu bir "sert hata" sayılır: USB'ye dönüş denemesi 4 s → 8 s … en çok 60 s geri çekilir. Kablo çıkıp takılınca sıfırlanır ve hemen denenir.
- **Kablo:** `MB/session ev=usb_cable state=connected|disconnected src=usb_state|battery`. `USB_STATE` bir kez gelince pil yok sayılır.
- **Taşıma sırasında girdi:**
  - Terfide eski kontrol bağlantısına BYE gitmez. Girdi ona yönlendirilmez, kuyruğundaki mesajlar yine gider.
  - Yeni bağlantıda ilk kayıt kanıt PING'idir. Host bu PING'de eski oturumu release-all + BYE(SUPERSEDED) ile kapatır (§3.3). Eski bağlantı istemcide ilk STREAM_CONFIG'de (host bunu kapatmadan sonra gönderir) ya da en geç 2 s'de kapanır.
  - UI, girdi modelini (`capture.onSessionReset()`) ve gönderim hedefini (`inputGen`) aynı UI çalıştırmasında değiştirir. Eski modelden (vuruş ortası, basılı tuş) üretilip bayat nesille gönderilen her mesaj reddedilir ve model unutulur. Bayat nesilli bir RELEASE_ALL reddi yeni oturumu düşürmez; eski bağlantı zaten kapanıyor ve host onu bırakıyor.
  - Süren bir kalem vuruşu geçişte kesilir: host bırakır, sonraki örnekler STROKE_START'a kadar hover olur. Hiçbir şey basılı kalmaz.

**Varsayımlar / tasarım kararları**
- Akış sırasındaki yoklama TCP bağlan-kapat değil, gerçek bağlantı denemesi. Yalnız bağlantı yokken (açılış seçimi ve Wi-Fi'de bağlı değilken yeniden tarama) TCP bağlan-kapat kullanılır. Port açıksa bu host'ta HELLO'suz tek bir bağlantı demek, ardından hemen USB'ye geçilir.
- Ucuz (yerel ret) denemeler 15 kez 2 s'de bir, sonra 10 s'de bir (planda belirtilmişti). Kablo değişimi bu sayacı sıfırlar.
- Clipboard: geçişte `ClipboardSync` yeni nesil için yeniden kuruluyor; UI `Connected` kaldığı için aksi halde yeni bağlantıdan gelen pano mesajları reddedilirdi.
- `SessionController.dispatch`: girdi izni kapanırken eskisi gibi hemen, açılırken artık eylemlerden **sonra** değişiyor. Normal ACCEPTED'da da kanıt PING'i ve STREAM_PREFS her zaman ilk kayıtlar oluyor.
- `onPong` yalnız güncel nesilden gelen PONG için çağrılıyor (`MbLog.gen`).

**Test edilmeyenler (tablet + Mac gerekli; açık bırakılan iki kabul maddesi)**
- Gerçek kesinti süresi (≤1–2 s hedefi).
- HarmonyOS'ta `USB_STATE` gelip gelmediği.
- Host'un `adb reverse`'ü kablo takıldıktan ne kadar sonra kurduğu.
- `adbd`'nin, host dinlemiyorken bağlantıyı kabul edip hemen kapatıp kapatmadığı (bu durumda açılış seçimi USB der, sonra Wi-Fi'ye düşer).

**Tablette doğrulanacaklar** (`adb logcat -s 'MB/session:*' 'MB/input:*'`, host logu açık)
1. **Mod ve açılış:** panelde "Otomatik"e bas (ya da `am start -n dev.matebridge.client/.MainActivity --es transport auto`).
   - Kablo takılı ve host `adb reverse` kurmuşken: `transport_pick mode=auto chosen=usb reason=usb_open`, akış USB'de.
   - Kablo yokken: `chosen=wifi reason=usb_refused`, akış Wi-Fi'de.
2. **Wi-Fi → USB:** Wi-Fi'de akarken kablo tak.
   - `usb_cable state=connected` gelmeli, ardından birkaç saniye içinde (host'un reverse kurma süresi + ≤2 s) yukarıdaki başarı dizisi.
   - Ekranda kesinti süresini ölç; panel açılmamalı. Host logunda `takeover_proving` → `session_superseded` → `session_started` sırası görülmeli.
   - İstatistik katmanında "Bağlantı: USB (otomatik)".
3. **Geçişte girdi:** geçiş anında kalemle çiziyor ve bir tuşu (ör. Shift) basılı tutuyor ol.
   - Mac'te takılı tuş, takılı tık ya da kendiliğinden devam eden çizgi olmamalı.
   - Geçişten sonra kalem, klavye, touchpad ve parmak normal çalışmalı.
   - `MB/input ev=session_reset` geçiş anında bir kez görünmeli.
4. **USB → Wi-Fi:** USB'de akarken kabloyu çek.
   - `usb_cable state=disconnected`, `Disconnected` (PONG zaman aşımı ya da kopma), ardından `transport_pick mode=auto chosen=wifi reason=usb_lost`.
   - Wi-Fi'de akış kullanıcı bir şey yapmadan geri gelmeli. Kabloyu yeniden takınca 2 numaradaki gibi USB'ye dönmeli.
5. **Elle modlar:** "Yalnız Wi-Fi"de kablo takılınca USB'ye geçilmemeli; "Yalnız USB"de bugünkü gibi (3 s sonra "USB bağlantısı yok" ipucu).
   - `--es transport wifi` ile açılış panel ayarını değiştirmemeli: sonraki normal açılış kayıtlı moda döner.
   - Wi-Fi'de akarken ve kablo yokken log gürültüsü olmamalı: `transport_migrate` satırı çıkmamalı (pil `plugged=0` → `disconnected`).

**Açık sorular**
- Kayıtlı `wifi` tercihi korunuyor (kart gereği). Kullanıcı daha önce panelden Wi-Fi seçtiyse Otomatik'i bir kez elle seçmesi gerekiyor. Tek kullanıcılı projede bir kerelik geçiş isteniyorsa kayıtlı değer görmezden gelinebilir; bu orkestratörün kararı.
- `ConnectMode.autoDiscover` ve `Transport.parse` artık üretim kodunda kullanılmıyor (testler `autoDiscover`'ı kullanıyor). Kapsam dışı temizlik olarak bırakıldı.
