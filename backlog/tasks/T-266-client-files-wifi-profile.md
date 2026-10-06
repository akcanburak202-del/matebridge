---
id: T-266
title: Client files/ — Wi-Fi profili: değişebilir hız tavanı + küçük istek şeridi, Wi-Fi kökü MateBridge/Wi-Fi, hızlı 404
status: todo
phase: 6
owner: android-client-dev
depends_on: []
decisions: [0035, 0015, 0028]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/files/
  - client-android/app/src/test/kotlin/dev/matebridge/client/files/
  - tools/dav-repro/
  - backlog/tasks/T-266-client-files-wifi-profile.md
---

## Amaç

Karar 0035 (ve 2026-10-06 eki) için tabletteki WebDAV sunucusunun Wi-Fi'a hazır parçaları. Bu kart **oturuma bağlamaz** (tünel, `FILES_NET`, ayar yok: T-269); yalnız `files/` içindeki saf/yerel parçalar. Tasarım: `docs/research/2026-10-05-wifi-files.md` §2 ve §4 "İstemci" (C1 satırı). **Büyük dosya koruması YOK** (0035 eki: boyut sınırı kaldırıldı); araştırmadaki `wifi_max_file` maddesini uygulama.

## Kabul

1. **`TokenBucket` çalışırken değişebilir tavan:** `setRate(bytesPerSec)` (iş parçacığı güvenli; bekleyen borç yeni hıza göre hesaplanır, aşırı uyku yok). Mevcut USB davranışı ve testleri değişmez.
2. **Küçük istek şeridi:** ≤ 32 KiB istek/yanıt gövdeleri (PROPFIND, küçük GET/PUT, başlıklar) ayrı küçük kovadan geçer (~256 KB/s, derinlik 32 KiB), büyük aktarımın borcunun arkasında beklemez. Toplam üst sınır = ana tavan + küçük şerit (belgelenir). USB profilinde şerit kapalı ya da etkisiz (bugünkü davranış).
3. **Wi-Fi profili:** `FilesConfig` için Wi-Fi değerleri (araştırma §2): patlama 64 KiB, kopya tamponu 16 KiB; bağlantı sınırları aynı (8 + 4). Tek yerde (`FilesConfig.wifi(...)` ya da eşdeğeri).
4. **Hız formülü (saf):** `filesCapBytesPerSec(videoKbps)` = clamp((48 − video_Mbps) / 8, 0,5, 3,0) MB/s (MB = 10^6). Örnekler: 30 Mbps → 2,25 MB/s; 15 → 3; 60 → 0,5. Video hızı bilinmiyorsa (0) en düşük değil, 2 MB/s.
5. **Wi-Fi kökü:** `storage/MateBridge/Wi-Fi/` (0035 eki). `FilesScope.directory`'nin güvenlik kurallarıyla (sembolik bağ yok, kanonik yol tam olarak `storage/MateBridge/Wi-Fi`, eksikse iki seviye de oluşturulur, başarısızsa null; asla üst klasöre ya da depolamaya geri düşmez). USB'nin `FilesRoot` seçimi değişmez. Log alanında yalnız sınıf (`root=wifi`), yol yok.
6. **Hızlı 404:** bilinen macOS yoklamaları depolamaya dokunmadan 404: `.hidden`, `.localized`, `.Trashes`, `.Spotlight-V100`, `.fseventsd`, `.VolumeIcon.icns`, `.TemporaryItems` (kök ve alt dizinlerde; GET/HEAD/PROPFIND). `._*` ve `.DS_Store` bugünkü `MetaStore` davranışında kalır.
7. **Ölçüm:** `tools/dav-repro` ile tablet olmadan 2 MB/s Wi-Fi profili: büyük dosya kopyası sürerken PROPFIND gecikmesi (p50/p95) şeritli ve şeritsiz; sonuç Handoff'a. Mac'te pencere açma (Finder dahil); `mount.swift` / komut satırı kullan.
8. JVM testleri: `setRate` (yükseltme/düşürme, borç), küçük şerit önceliği, formül tablosu, Wi-Fi kök güvenliği (sembolik bağ, dosya, eksik klasör), hızlı 404 listesi.

## Plan

1. `TokenBucket.setRate` (kilit altında yeni hız, eski hızla settle; borç bayt olarak kalır). `acquire` 100 ms dilimlerle uyur, hız değişmişse kalan borcu yeni hızla yeniden hesaplar (artışta aşırı uyku yok). `ByteBudget` arayüzü: akışlar `TokenBucket` yerine bunu alır.
2. Küçük şerit: `LaneBudget` + bağlantı/yön başına `Lane`: her isteğin/yanıtın ilk `smallThresholdBytes` (32 KiB) baytı küçük kovadan (256 KB/s, derinlik 32 KiB), kalanı ana kovadan; her istek sonunda `reset()`. `smallRateBytesPerSec = 0` (USB varsayılanı) = şerit yok. Toplam üst sınır = ana + küçük hız. `DavServer.setRate` ana kovayı değiştirir.
3. `FilesConfig.wifi(cap)`; `filesCapBytesPerSec(videoKbps)`.
4. Wi-Fi kökü: `FilesRoot` enum'una DOKUNMADAN (ayar arayüzünde seçenek olmasın) `WifiFilesRoot.directory(storage)`; `FilesScope.directory` ile ortak `safeSubdirectory` (seviye seviye: sembolik bağ yok, kanonik yol tam eşit, eksikse oluştur, aksi null).
5. Hızlı 404: `MetaStore.isProbeName`; `DavHandler.dispatch` içinde GET/HEAD/PROPFIND için herhangi bir segment eşleşirse 404 (çözümlemeden önce).
6. Testler: setRate, şerit önceliği, formül, Wi-Fi kökü, 404 (sunucu testi). `tools/dav-repro`: `MB_DAV_PROFILE=wifi`, `MB_DAV_LANE=0/1` ve bir PROPFIND gecikme ölçüm betiği (komut satırı, GUI yok).

## Handoff

## Open questions
