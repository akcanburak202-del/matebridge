---
id: T-135
title: Tablet — dosyalar için WebDAV sunucusu (yalnız localhost, jetonlu, hız tavanlı) + FILES_INFO
status: review
phase: 5
owner: android-client-dev
depends_on: []
decisions: [0015]
files:
  - client-android/app/src/
  - backlog/tasks/T-135-client-files-webdav.md
---

## Amaç

Karar 0015: Mac'ten tabletteki dosyalara Finder ile erişim. Tablet tarafı: WebDAV sunucusu ve `FILES_INFO` (PROTOCOL §4 0x09, `HELLO.capabilities` bit10 `FILES`, fixture `files_info_ready`, `files_info_off`). Kullanıcının koşulu: **görüntü kalitesi ve akıcılık bozulmamalı.**

## Kabul kriterleri

- [x] Protokol: `FILES_INFO` kodlama/çözme, `FixtureTest`'e iki fixture; HELLO'da bit10 `FILES`.
- [x] **Sunucu (yeni bağımlılık yok, kendi kodumuz):** yalnızca `127.0.0.1`'e bağlanır (port tercihen 47010, doluysa sistemin verdiği). Yöntemler: `OPTIONS` (`DAV: 1, 2`), `PROPFIND` Depth 0/1 (Depth infinity → 403), `GET`/`HEAD` (tek aralıklı `Range`, `206`), `PUT` (akışla diske, geçici dosya + taşıma), `DELETE`, `MKCOL`, `MOVE`, `COPY` (`Destination`, `Overwrite`), `LOCK`/`UNLOCK` (Finder'ın yazma için istediği sahte, bellek içi kilitler). Finder'ın beklediği özellikler: `resourcetype`, `getcontentlength`, `getlastmodified`, `creationdate`, `getcontenttype`, `getetag`, `displayname`; UTF-8 / Türkçe karakterli adlar, URL kodlama doğru. Kök: `Environment.getExternalStorageDirectory()`; yol kök dışına çıkamaz (`..`, sembolik bağ kaçışı reddedilir).
- [x] **Kimlik doğrulama:** her istek `matebridge` / jeton (128 bit rastgele, 32 küçük harf hex, her sunucu başlangıcında yeni). Hem Digest (MD5, `qop=auth`) hem Basic kabul edilir; 401 yanıtı Digest sunar. Jetonsuz/yanlış → 401. Jeton ve kimlik bilgisi loglanmaz.
- [x] **İzin:** "Tüm dosyalara erişim" (`MANAGE_EXTERNAL_STORAGE`). Ayarlar panelinde "Tablet dosyalarını Mac'te göster" anahtarı (varsayılan kapalı); açınca izin yoksa sistem izin ekranına götürür. Anahtar kapalı ya da izin yoksa sunucu çalışmaz ve `FILES_INFO OFF`.
- [x] **FILES_INFO:** ACCEPTED oturum başında bir kez ve durum/port/jeton değişince gönderilir.
- [x] **Görüntüyü bozmama:** sunucu iş parçacıkları düşük öncelikli (`THREAD_PRIORITY_BACKGROUND`); toplam aktarım hızı token bucket ile sınırlı (sabit, başlangıç 20 MB/s, kolay değişsin); eşzamanlı bağlantı sınırı (ör. 4); sınırlı tampon (akış, tüm dosya belleğe alınmaz). Boştayken iş parçacığı bekler, CPU harcamaz. Uygulama arka plana gidince/oturum yokken sunucu durabilir (seçimini Handoff'ta yaz) ama açık aktarımlar düzgün kapanır.
- [x] Log: `MB/files ev=server state=on|off port=…`, istek başına değil saniyelik özet (`ev=stats reqs=… bytes_out=… bytes_in=… throttled_ms=…`); dosya adı/yolu loglanmaz.
- [x] Testler (JVM): yol güvenliği, Range ayrıştırma, PROPFIND XML (Türkçe ad), Digest doğrulama, token bucket, FILES_INFO fixture. `./scripts/check.sh` geçiyor — **not:** host tarafı fixture testi T-136 birleşene kadar kırmızı olabilir.

## Kapsam dışı

Wi-Fi üzerinden erişim; cihaz testi (orkestratör).

## Plan

1. **Protokol:** `FilesInfo(state, port, token)` (0x09) `Messages.kt` + `Codec.kt`; `Capabilities.FILES = 1 shl 10`; `FixtureTest`'e `files_info_ready`/`files_info_off`. `toString` jetonu göstermez.
2. **Oturum:** `SessionMachine` `initialFiles: FilesInfo?` (null = özellik yok, hiç gönderilmez) + `Event.SetFiles`; ACCEPTED'da AUDIO_PREFS'ten sonra bir kez, değişince yeniden. `SessionController.setFilesInfo()` (tek yuvalı posta kutusu, diğerleri gibi); log yalnız `state`/`port`.
3. **Saf mantık (`client/files/`, JVM testli):**
   - `DavPath`: istek hedefini `/`'den böl, her parçayı sıkı UTF-8 yüzde-çöz; `.`/`..`/NUL/`/` içeren parça reddi; kökten çözümle; NFC/NFD (Finder NFD gönderebilir) eşleştirme; kanonik yol kök içinde mi (sembolik bağ kaçışı reddi); `href` kodlama; `Destination` ayrıştırma.
   - `ByteRange`: tek aralık (`a-b`, `a-`, `-n`), 416, çoklu/bozuk → tam yanıt.
   - `DavXml`: 207 multistatus (Türkçe ad, XML kaçışı), LOCK yanıtı, RFC 1123 / ISO 8601 tarih, içerik türü tablosu.
   - `DigestAuth`: Digest MD5 `qop=auth` (RFC 2617 vektörü), HMAC'li durumsuz nonce (süre aşımı → `stale=true`), Basic; sabit zamanlı karşılaştırma.
   - `TokenBucket` (20 MB/s, sabit `FilesConfig`'te), `FilesStats` (saniyelik özet satırı, yalnız etkinlik varken).
   - `HttpIo`: istek başı ayrıştırma (sınırlı başlık), chunked giriş (Finder PUT'ları chunked gönderir), Content-Length sınırlı giriş, chunked çıkış (büyük PROPFIND belleğe alınmaz), `Expect: 100-continue`.
4. **Sunucu (`DavServer` + `DavHandler`, yeni bağımlılık yok):** `127.0.0.1`, port 47010 → doluysa 0. Kabul iş parçacığı + bağlantı başına iş parçacığı (en çok 4; dolunca boşta bekleyen keep-alive bağlantısı kapatılır, yoksa kabul bekler). İş parçacıkları `THREAD_PRIORITY_BACKGROUND` (Android tarafından enjekte edilen kanca). 64 KB tampon, tüm aktarım token bucket'tan geçer. Yöntemler kartta yazdığı gibi; PUT geçici dosya + taşıma, hata olursa geçici dosya silinir. Boşta: `accept()`/`read()` bekler, zamanlayıcı yok. Durdurma: dinleyici + tüm bağlantı soketleri kapatılır, yarım PUT'lar silinir. JVM'de gerçek localhost soketiyle uçtan uca test.
5. **Android yapıştırıcısı (`FilesController`):** `MANAGE_EXTERNAL_STORAGE` (manifest), `Environment.isExternalStorageManager()`; ayar "Tablet dosyalarını Mac'te göster" (varsayılan kapalı, `Settings.filesShare`), açınca izin yoksa `ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION` (yoksa genel ekran). Sunucu **yalnız etkinlik ön plandayken** (onStart→onStop) çalışır: oturum zaten onStop'ta bitiyor. Her başlatmada yeni jeton; READY yalnız dinleyici hazır olunca, OFF durdurmadan önce gönderilir. Ayarlar panelinde yeni "Tablet dosyaları" bölümü: anahtar + durum satırı.
6. `./scripts/check.sh`, Handoff, `status: review`.

## Handoff

- **Commit:** `1a9b83c` (uygulama), `d2951c8` (Codex inceleme düzeltmeleri), plan `a3b0d9a`; kart güncellemeleri ayrı commit. Dal `task/T-135-client-files-webdav` (e73df47'den).
- **check.sh:** Android (client + probe'lar), fixture/crypto denetimleri OK. Tek kırmızı: `swift test (host-mac)` → `FixtureTests.everyFixtureFileHasATestCase` (`files_info_ready`/`files_info_off` host'ta henüz yok; T-136 ile düzelir, kartta beklenen durum).
- **Dosyalar:**
  - Protokol: `protocol/Messages.kt` (`FilesInfo`, `MsgType.FILES_INFO`, `Capabilities.FILES`; `toString` jetonu göstermez), `protocol/Codec.kt`.
  - Oturum: `session/SessionMachine.kt` (`initialFiles`, `Event.SetFiles`; ACCEPTED'da AUDIO_PREFS'ten sonra bir kez, değişince yeniden; göç sonrası yeni bağlantıda da), `session/SessionController.kt` (`setFilesInfo`, posta kutusu, loglar `files_info_set|sent state= port=`), `session/Settings.kt` (`files_share`, varsayılan kapalı).
  - Yeni `files/`: `MetaStore` (Finder üst verisi, bellekte), `DavPath`, `ByteRange`, `DavXml`, `DigestAuth`, `TokenBucket` (+`FilesStats`), `HttpIo`, `DavHandler`, `DavServer`, `FilesConfig`, `FilesSwitch`, `FilesController` (Android yapıştırıcısı).
  - UI: `settings/SettingsCatalog.kt` (yeni bölüm "Tablet dosyaları": anahtar + durum satırı), `MainActivity.kt`, `AndroidManifest.xml` (`MANAGE_EXTERNAL_STORAGE`).
  - Testler: `files/DavPathTest`, `files/FilesLogicTest`, `files/DavServerTest` (gerçek 127.0.0.1 soketiyle uçtan uca), `session/FilesInfoMachineTest`, `FixtureTest` (+2 fixture), `SettingsCatalogTest`.
- **Orkestratör kararı uygulandı — `/MatePad/` öneki:** paylaşılan depolama `/MatePad/...` altında. `PROPFIND /` (Depth 0/1) yalnızca `/` ve `/MatePad/` döner; `/` salt okunur (OPTIONS/PROPFIND dışı → 405); `/MatePad` dışındaki her yol → 404 (OPTIONS her yerde 200); MOVE/COPY `Destination` `/MatePad/` dışındaysa ya da `/MatePad/`'in kendisiyse → 403. Kimlik doğrulama `/` dahil her istekte. Host `http://localhost:<yerel>/MatePad/` bağlamalı.
- **Codex (high) inceleme düzeltmeleri (`d2951c8`):**
  1. *(P1, veri kaybı)* MOVE/COPY: hedef kaynağın atası, kendisi ya da altıysa hiçbir şeye dokunmadan reddedilir (ata/alt → 409, aynı yol → 403). İlişki kanonik yolla ve (harf/normalizasyon duyarsız depolama için) üst zincirleri boyunca `isSameFile` ile bulunur. Var olan hedef artık önce silinmiyor: gizli geçici ada **kenara alınır**, işlem başarılıysa silinir; başarısızlık/iptalde yarım sonuç silinir ve eski hedef geri konur. Kaynak yoksa (404) hiçbir şey değişmez. Testler: `ancestorOrDescendantDestinationNeverDeletesTheSource`, `overwritingMoveReplacesTheDestinationOnlyOnSuccess`.
  2. *(P2)* Sunucu durunca COPY ve özyinelemeli DELETE her dosyada/tamponda iptali denetler; yarım kopya temizlenir, kenara alınan hedef geri konur. Yeni sunucu, durdurulan öncekinin tüm iş parçacıkları bitene kadar (en çok 5 sn, `DavServer(after=…)` + `awaitTermination`) dinlemeye başlamaz; aşılırsa `ev=predecessor_busy`.
  3. *(P2)* Sunucu içi COPY (ve MOVE'un kopya yedeği) baytları aynı token bucket'tan geçer; `ev=stats`'a `bytes_copied=` alanı eklendi. Test: `stopCancelsARateLimitedCopyAndTheNextServerWaitsForIt` (1 MB/s'de 3 MB kopya, durdurma, yarım dosya yok, yeni sunucu eskisi bitince dinliyor).
  4. *(P2)* `ev=stats` artık istek başına zorlanmıyor: en çok saniyede bir; yalnız sunucu durunca (son iş parçacığı bitince) son özet zorlanır. Test: `statsAreNotWrittenPerRequest`.
  5. *(açık soru kapatıldı)* Finder üst verisi (`._*`, `.DS_Store`) paylaşılan depolamaya **hiç yazılmaz**: PUT/GET/HEAD/PROPFIND/DELETE/MOVE/COPY/LOCK sunucu ömrü boyunca bellekte, sınırlı bir depoda (`MetaStore`: 1024 kayıt, kayıt başı 512 KB, toplam 8 MB, LRU; daha büyüğü saklanmaz). Klasör taşınınca/silinince üst verisi de taşınır/silinir. Depolamada zaten var olan bu adlı dosyalar listede gizlenir ve dokunulmaz; gerçek bir dosya üst veri adına taşınamaz (403). Test: `finderMetadataStaysInMemory`, `metaStoreIsBoundedAndLeastRecentlyUsedGoesFirst`.
- **Seçimler / varsayımlar:**
  - **Yaşam döngüsü:** sunucu yalnız etkinlik ön plandayken (onStart→onStop) + anahtar açık + izin varken çalışır; arka planda oturum zaten bitiyor. Her başlatmada yeni jeton. READY yalnız soket dinlemeye başlayınca, OFF durdurmadan önce gönderilir (kilit altında, READY OFF'u geçemez). Durdurma: dinleyici + tüm bağlantı soketleri kapanır; yarım PUT'un geçici dosyası silinir (test var), GET kısa biter.
  - **Görüntüyü koruma:** tüm iş parçacıkları `THREAD_PRIORITY_BACKGROUND`; tüm gelen+giden baytlar (başlıklar dahil) tek token bucket'tan: 20 MB/s, 256 KB patlama (`FilesConfig.RATE_BYTES_PER_SEC`); en çok 4 bağlantı (dolunca en uzun boşta bekleyen keep-alive kapatılır, hepsi meşgulse kabul bekler); bağlantı başına 64 KB tampon; büyük PROPFIND chunked akar (belleğe alınmaz). Boşta zamanlayıcı yok; boş keep-alive 30 sn sonra kapanır.
  - **HTTP:** Finder'ın chunked PUT'u ve `Expect: 100-continue` destekli; `X-Expected-Entity-Length`/`Content-Length` boş alandan büyükse 507. PUT `.mbput-<hex>.tmp` → taşıma; bu geçici adlar listede gizli. LOCK eşlenmemiş URL'de boş dosya oluşturur (201); yenileme `If` başlığındaki jetonla. Depth infinity / Depth yok → 403. PROPFIND her zaman tüm özellikleri döner (+ `supportedlock`, kökte kota).
  - **Adlar:** Mac NFD gönderebilir: istenen ad yoksa NFC/NFD karşılığı aranır, yeni adlar NFC oluşturulur. Büyük/küçük harf duyarsız depolamada (FUSE) aynı dosyaya MOVE (yalnız harf/normalizasyon değişikliği) "hedefi sil" yapmaz, doğrudan yeniden adlandırır.
  - **Güvenlik:** `..`/`.`/`%2f`/NUL içeren parça reddi (400), kökten kaçan sembolik bağlar 403 ve listede gösterilmez. Digest MD5 `qop=auth`, HMAC'li durumsuz nonce (1 sa, sonra `stale=true`), Basic da kabul; 401 yalnız Digest sunar. Jeton/başlık/yol/ad loglanmaz (testte jetonun loglarda olmadığı denetleniyor).
  - **Log:** `MB/files ev=server state=on port=…` / `state=off port=0 reason=disabled|no_permission|background|destroy|failed|ended`, etkinlik varken saniyelik `ev=stats reqs= bytes_out= bytes_in= throttled_ms=`; `ev=request_error method= kind=` (yalnız sınıf adı).
  - HELLO'da bit10 `FILES` her zaman açık (anahtar kapalıyken de; FILES_INFO OFF gider).
- **Test EDİLMEDİ (tablet gerekiyor) — orkestratörün cihazda bakacakları:**
  1. Ayarlar → "Tablet dosyaları" → anahtarı aç: HarmonyOS'ta "Tüm dosyalara erişim" ekranı açılıyor mu (`ev=permission_screen step=0` ya da 1/2), izin verip dönünce durum satırı "hazır" ve logda `MB/files ev=server state=on port=47010`, `MB/session ev=files_info_sent state=1 port=47010`.
  2. Elle doğrulama (T-136 öncesi): `adb forward tcp:47010 tcp:47010`, sonra jetonu bilmeden `curl -i -X PROPFIND -H 'Depth: 1' http://localhost:47010/MatePad/` → 401. (Jeton loglanmıyor; Finder ile bağlama T-136'yı bekliyor.) T-136 sonrası: Finder'da "MatePad" birimi, Türkçe adlı klasör/dosya görünümü, büyük dosyayı Mac'e ve Mac'ten tablete kopyalama, yeniden adlandırma, silme, yeni klasör.
  3. **Akıcılık:** akış (hareketli içerik) sürerken büyük kopya: görüntüde takılma/kalite düşüşü var mı, `ev=stats` satırlarında `bytes_out` ~20 MB/s civarı ve `throttled_ms` artıyor mu; gerekirse `FilesConfig.RATE_BYTES_PER_SEC` ayarlanmalı.
  4. Uygulama arka plana gidince `ev=server state=off reason=background`; kopya sırasında arka plana alınca tablette `.mbput-*.tmp` kalıntısı kalmamalı.
  5. Finder'la kopyalama/yeniden adlandırmadan sonra tablette (Dosyalar/Galeri) hiçbir `._*` ya da `.DS_Store` görünmemeli; Finder bu yüzden hata vermemeli (üst veri yalnız bellekte, sunucu yeniden başlayınca kaybolur).
  6. Büyük bir klasörü Finder içinde kopyala (sunucu içi COPY) ve sürerken uygulamayı arka plana al: yarım kopya kalmamalı; `ev=stats ... bytes_copied=` ~20 MB/s'yi aşmamalı.
- **Açık sorular:**
  - `PROPPATCH` desteklenmiyor (405). macOS webdavfs'in kullanmadığını varsayıyorum; cihazda Finder bir hata gösterirse eklenmeli.
  - Android 11+ `Android/data` ve `Android/obb` "Tüm dosyalara erişim" ile de okunamaz; bu klasörler boş görünecek (beklenen).
