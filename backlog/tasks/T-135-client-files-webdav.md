---
id: T-135
title: Tablet — dosyalar için WebDAV sunucusu (yalnız localhost, jetonlu, hız tavanlı) + FILES_INFO
status: in_progress
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

- [ ] Protokol: `FILES_INFO` kodlama/çözme, `FixtureTest`'e iki fixture; HELLO'da bit10 `FILES`.
- [ ] **Sunucu (yeni bağımlılık yok, kendi kodumuz):** yalnızca `127.0.0.1`'e bağlanır (port tercihen 47010, doluysa sistemin verdiği). Yöntemler: `OPTIONS` (`DAV: 1, 2`), `PROPFIND` Depth 0/1 (Depth infinity → 403), `GET`/`HEAD` (tek aralıklı `Range`, `206`), `PUT` (akışla diske, geçici dosya + taşıma), `DELETE`, `MKCOL`, `MOVE`, `COPY` (`Destination`, `Overwrite`), `LOCK`/`UNLOCK` (Finder'ın yazma için istediği sahte, bellek içi kilitler). Finder'ın beklediği özellikler: `resourcetype`, `getcontentlength`, `getlastmodified`, `creationdate`, `getcontenttype`, `getetag`, `displayname`; UTF-8 / Türkçe karakterli adlar, URL kodlama doğru. Kök: `Environment.getExternalStorageDirectory()`; yol kök dışına çıkamaz (`..`, sembolik bağ kaçışı reddedilir).
- [ ] **Kimlik doğrulama:** her istek `matebridge` / jeton (128 bit rastgele, 32 küçük harf hex, her sunucu başlangıcında yeni). Hem Digest (MD5, `qop=auth`) hem Basic kabul edilir; 401 yanıtı Digest sunar. Jetonsuz/yanlış → 401. Jeton ve kimlik bilgisi loglanmaz.
- [ ] **İzin:** "Tüm dosyalara erişim" (`MANAGE_EXTERNAL_STORAGE`). Ayarlar panelinde "Tablet dosyalarını Mac'te göster" anahtarı (varsayılan kapalı); açınca izin yoksa sistem izin ekranına götürür. Anahtar kapalı ya da izin yoksa sunucu çalışmaz ve `FILES_INFO OFF`.
- [ ] **FILES_INFO:** ACCEPTED oturum başında bir kez ve durum/port/jeton değişince gönderilir.
- [ ] **Görüntüyü bozmama:** sunucu iş parçacıkları düşük öncelikli (`THREAD_PRIORITY_BACKGROUND`); toplam aktarım hızı token bucket ile sınırlı (sabit, başlangıç 20 MB/s, kolay değişsin); eşzamanlı bağlantı sınırı (ör. 4); sınırlı tampon (akış, tüm dosya belleğe alınmaz). Boştayken iş parçacığı bekler, CPU harcamaz. Uygulama arka plana gidince/oturum yokken sunucu durabilir (seçimini Handoff'ta yaz) ama açık aktarımlar düzgün kapanır.
- [ ] Log: `MB/files ev=server state=on|off port=…`, istek başına değil saniyelik özet (`ev=stats reqs=… bytes_out=… bytes_in=… throttled_ms=…`); dosya adı/yolu loglanmaz.
- [ ] Testler (JVM): yol güvenliği, Range ayrıştırma, PROPFIND XML (Türkçe ad), Digest doğrulama, token bucket, FILES_INFO fixture. `./scripts/check.sh` geçiyor — **not:** host tarafı fixture testi T-136 birleşene kadar kırmızı olabilir.

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

(ajan doldurur)
