---
id: T-135
title: Tablet — dosyalar için WebDAV sunucusu (yalnız localhost, jetonlu, hız tavanlı) + FILES_INFO
status: todo
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

(ajan doldurur)

## Handoff

(ajan doldurur)
