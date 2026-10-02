---
id: T-137
title: Dosyalar — Finder'da bağlama her seferinde tam 90 s sürüyor (kök neden + düzeltme)
status: done
phase: 5
owner: android-client-dev
depends_on: [T-135, T-136]
decisions: [0015]
files:
  - client-android/app/src/
  - host-mac/Sources/MateBridgeHost/Files/
  - host-mac/Sources/MateBridgeCore/Files/
  - host-mac/Tests/
  - tools/dav-repro/
  - backlog/tasks/T-137-files-mount-90s-delay.md
---

## Amaç

Cihaz (2026-10-02 ~17:25 ve ~17:33): "Tablet dosyalarını aç" → `ev=mount result=ok ms=90187` ve ikinci kez `ms=90120` (izin penceresi ikinci seferde yok). Tablette: tek istek (`reqs=1 bytes_in=131 bytes_out=918`), sonra **90 s hiç istek yok**, sonra normal trafik (`reqs=7`, `reqs=92`) ve birim açılıyor. Sunucu her yönteme (OPTIONS dahil) `401 Digest` veriyor. NetFS çağrısı: `NetFSMountURLAsync(http://127.0.0.1:<port>/MatePad/, user "matebridge", password=jeton, openOptions UI yok + AllowLoopback, SoftMount)`.

Hipotezler (doğrula, tahminle düzeltme yapma): (a) webdavfs/NetAuth ilk 401'de kimlik bilgisi için UI/agent bekliyor, 90 s zaman aşımından sonra verilen kimlik bilgisini kullanıyor; (b) sunucunun bir yanıtı (ör. OPTIONS/ilk istek) gövde uzunluğu / keep-alive yüzünden istemciyi okuma zaman aşımına kadar bekletiyor; (c) Digest/Basic seçimi.

## Kabul kriterleri

- [ ] **Mac'te tekrar üretim:** `DavServer` JVM'de (Android'siz, test sınıflarıyla) Mac'te bilinen bir jetonla çalıştırılır (`tools/dav-repro/` altında betik; Android Studio JDK: `/Applications/Android Studio.app/Contents/jbr/Contents/Home`), ve aynı NetFS seçenekleriyle (küçük Swift betiği ya da `mount_webdav`) bağlanır; süre ve istek/yanıt dökümü (yöntem, durum kodu, başlıklar, zamanlar — jeton hariç) alınır. 90 s gecikme yeniden üretilir.
- [ ] Kök neden bulunur ve düzeltilir (sunucu ve/veya host tarafı). Hedef: bağlama < 3 s. Güvenlik modeli değişmez (her istek kimlik doğrulamalı; jeton loglanmaz; yalnız 127.0.0.1).
- [ ] Düzeltmeden sonra tekrar üretim betiğiyle bağlama süresi ölçülür ve Handoff'a yazılır. Mevcut testler + yeni regresyon testi; `./scripts/check.sh` geçiyor.
- [ ] Mac'te gerçek `/Volumes` bağlaması yapılırsa test sonunda ayrılır; çalışan MateBridge host'una ve onun `/Volumes/MatePad` birimine dokunulmaz (başka port ve birim adı kullan).

## Plan

1. `tools/dav-repro/`: `DavRepro.java` (JDK `javac` ile; Mac'te `kotlinc` yok) DavServer'ı derlenmiş debug sınıflarından JVM'de çalıştırır, önüne başlık döküm vekili (proxy) koyar (Authorization yalnız şema, jeton hiç yazılmaz); `mount.swift` host'un aynı NetFS seçenekleriyle (NoUI, AllowLoopback, SoftMount) geçici bir dizine bağlar (MountAtMountDir, /Volumes'a dokunmaz), süreyi + statfs'i yazar, ayırır; `run.sh` hepsini 47811 portunda birleştirir (47010 reddedilir).
2. Tekrar üret, döküm + `log show` (webdavfs_agent, NetAuthSysAgent, kernel webdav_fs) ile 90 s boşluğun kaynağını bul; sunucu yanıtı değişkenleriyle (chunked/Content-Length, kota yok/0/küçük) deney yap.
3. Kök nedene göre en küçük düzeltme + regresyon testi; ölçümü Handoff'a yaz.

## Handoff

**Commit:** `c064707` (düzeltme + araç), plan `0b46adc`. Dal: `task/T-137-files-mount-delay` (f85475b'den).

**Kök neden (kanıtlı):** Sunucu PROPFIND yanıtlarında RFC 4331 kota özelliklerini (`quota-available-bytes`, `quota-used-bytes`) veriyordu. macOS webdavfs bağlamadan önce kotayı soruyor; değer ≠ 0 ise çekirdek `WEBDAV_MOUNT_SUPPORTS_STATFS` bayrağını tutuyor ve `mount(2)` içindeki ilk statfs'te (`pm_statfstime == 0`) `webdavfs_agent`'a `WEBDAV_STATFS` gönderiyor. Ajan o sırada kendisi `mount(2)` içinde olduğundan yanıt vermiyor; çekirdek 9 × 10 s bekleyip vazgeçiyor (`WEBDAV_SO_RCVTIMEO_SECONDS 10`, `WEBDAV_MAX_SOCK_RCV_TIMEOUTS 9`) → her bağlama tam 90 s. Kanıt:
- Döküm: OPTIONS 401 → Digest ile 200 → PROPFIND Depth 0 (207) → kota PROPFIND (207, tam yanıt, `0\r\n\r\n` dahil) → **90 s hiç istek yok** → aynı kota PROPFIND'ı yeniden (90 s sonra, o arada bizim 30 s boşta zaman aşımımızla kapanmış bağlantıda) → normal trafik. Cihaz loguyla aynı desen.
- Sistem logu: `kernel (webdav_fs) webdav_sendmsg: sock_receive() timeout. vnop: 15` tam 90 s'de (15 = `WEBDAV_STATFS`, webdav.h).
- Deneyler (her biri gerçek NetFS bağlaması): kota var → 90 120 / 90 094 / 90 118 ms; PROPFIND chunked yerine Content-Length → 90 118 ms (etkisiz); kota küçük değer (10/5 GiB) → 90 091 ms; kota 0/0 → 80 ms; kota yok → 85 ms. Hipotez (a) UI/NetAuth ve (c) Digest/Basic değil: kimlik doğrulama 1 ms'de bitiyor; (b) gövde uzunluğu/keep-alive değil.
- Kaynak: apple-oss-distributions/webdavfs `webdav_vfsops.c` (`webdav_vfs_getattr`, `webdav_vfs_statfs`).

**Düzeltme:** `DavXml.response` kota özelliklerini hiç yazmıyor (`DavEntry.quota` ve `DavHandler.quota()` kaldırıldı). Birim artık "boyut bilgisi yok" diyor (`VOL_CAP_FMT_NO_VOLUME_SIZES`, Apache mod_dav gibi): `volumeSupportsVolumeSizes=false`, statfs 0. Güvenlik modeli aynı (her istek kimlik doğrulamalı, yalnız 127.0.0.1, jeton loglanmıyor). Host tarafında değişiklik gerekmedi.

**Ek hata (aynı ölçümde bulundu):** `TokenBucket.reserve` içinde `elapsed(ns) * rate` Long taşması: 20 MB/s'de ~7,7 dk boşluktan sonra ilk bayt dakikalarca uyuyabiliyordu (tekrar üretimde 200 MB/s ile 90 s sonra `throttled_ms=2187`). Double'a çevrildi; regresyon testi eklendi.

**Ölçüm (tools/dav-repro/run.sh, Mac, JVM DavServer + NetFS, host'un seçenekleri):** önce **90 092–90 120 ms**; sonra **83 / 89 / 111 ms** (geçici dizine), **97 ms** (`/Volumes/MatePad-1`, `MB_DAV_VOLUMES=1`, hemen ayrıldı). Bağlama sonrası liste 25 ms, 1 MB yazma + geri okuma 18 ms.

**Dosyalar:** `client-android/app/src/main/kotlin/dev/matebridge/client/files/{DavXml,DavHandler,TokenBucket}.kt`, testler `DavServerTest.kt` (`noQuotaPropertiesSoMacMountsAtOnce`), `FilesLogicTest.kt` (`tokenBucketRefillDoesNotOverflowAfterAVeryLongIdle`, XML testinde kota yok), `tools/dav-repro/{DavRepro.java,mount.swift,run.sh}`.

**Araç:** `tools/dav-repro/run.sh [port]` (varsayılan 47811; 47010 reddedilir). Jeton `openssl rand` ile, yalnız ortam değişkeninde; dökümde Authorization yalnız şema. `MB_DAV_RAW=1` gövdeleri de döker. Çalışan host'a ve `/Volumes/MatePad`'e dokunulmadı; test bağlamaları ayrıldı.

**check.sh:** ALL OK.

**Varsayımlar:** Finder boyut bilgisi olmayan WebDAV biriminde kopyalamayı engellemez (Apache mod_dav birimleri gibi); Finder'da "boş alan" gösterilmez. Kota yeniden istenirse bu macOS hatası yüzünden bağlama tekrar 90 s olur.

**Test edilmedi / tablette kontrol:**
1. Yeni APK + host ile "Tablet dosyalarını aç": host logunda `ev=mount result=ok ms=` < 3000 olmalı (önce ~90 000).
2. Finder'da birim açılıyor, klasörler listeleniyor; Finder'la Mac → tablet büyük bir dosya kopyası "yetersiz alan" uyarısı vermeden tamamlanıyor; tablet → Mac kopya çalışıyor.
3. Uygulama ~10 dk boşta kaldıktan sonra ilk dosya isteği gecikmesiz (TokenBucket düzeltmesi): tablet logunda `throttled_ms` küçük kalmalı.
4. Bağlama sırasında ve büyük kopya sırasında görüntü akıcılığı bozulmuyor (değişmedi, kontrol amaçlı).

## Open questions

- Finder'da boş alan bilgisi artık yok. İstenirse tek yol: macOS bu hatayı düzeltene kadar yok (bağlamadan sonra kota vermek işe yaramaz; çekirdek kararı bağlama anında veriyor ve bir daha sormuyor).
