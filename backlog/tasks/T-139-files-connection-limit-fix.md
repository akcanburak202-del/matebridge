---
id: T-139
title: Dosyalar — bağlantı sınırı 8, yalnız gerçekten boştaki bağlantıyı düşür, ilerlemeyen yazımı kapat
status: review
phase: 5
owner: android-client-dev
depends_on: [T-138]
decisions: [0015]
files:
  - client-android/app/src/
  - tools/dav-repro/
  - backlog/tasks/T-139-files-connection-limit-fix.md
---

## Amaç

T-138 araştırması (kart Handoff'u, `tools/dav-repro`): 4 uzun GET (webdavfs tüm dosya indirmesi, ör. Finder video küçük resmi) bağlantı sınırını (4) doldurunca `DavServer.admit()` yeni bağlantıları sonsuza kadar bekletiyor (küçük kopya hiç ulaşmıyor, Finder "beklenmedik hata", çıkarma "kullanımda"); bir yer boşken de yeni kabul edilmiş, başlığı henüz okunmamış bağlantılar "boşta" sayılıp birbirini düşürüyor (2 318–4 196 bağlantılık canlı kilit). Kullanıcı düzeltmeyi onayladı (2026-10-02).

## Kabul kriterleri

- [x] `FilesConfig.MAX_CONNECTIONS` 4 → 8.
- [x] Düşürme yalnızca **gerçekten boştaki** keep-alive bağlantıya: en az bir isteği tamamlamış, ≥ ~1 s yeni istek beklemede, okunmamış bayt yok. İlk isteği bitmemiş bağlantı asla düşürülmez. Boşta bağlantı yoksa yeni bağlantı sonsuza kadar bekletilmez: kısa süre (ör. ≤ 2 s) bekler, sonra `503 Service Unavailable` + `Retry-After: 1` ile kapatılır (webdavfs yeniden dener) — seçimini testle gerekçelendir.
- [x] Yanıt yazımı ~30 s hiç ilerlemezse bağlantı kapatılır (yazma zaman aşımı; token bucket beklemesi "ilerleme yok" sayılmaz).
- [x] Regresyon testleri (JVM): 4 uzun GET sürerken 5. ve 6. küçük istek < 1 s yanıt alır; yeni bağlantılar birbirini düşürmez (bağlantı sayısı sınırlı kalır); ilerlemeyen yazım 30 s'de (testte kısaltılabilir sabit) kapanır.
- [x] `tools/dav-repro` ile Mac'te öncesi/sonrası (run8 ve run6 senaryoları) ölçülür, Handoff'a yazılır. **Arayüz yok:** `open`, Finder AppleScript, NetFS otomatik açma, Finder tetikleyicisi (`MB_BULK_ALLOW_UI`) **kullanılmaz** — Mac'in tek ekranı kullanıcının tableti.
- [x] Toplam hız tavanı (20 MB/s) ve güvenlik modeli değişmez. `./scripts/check.sh` geçiyor.

## Plan

1. `FilesConfig`: `MAX_CONNECTIONS` 4 → 8; yeni ayarlar (testte kısaltılabilir): `evictIdleMs` (1 000), `overflowConnections` (4), `admitWaitMs` (2 000), `writeTimeoutMs` (30 000).
2. `DavServer` kabul kuralı:
   - Bağlantı yalnızca **gerçekten boştayken** tahliye edilebilir: en az bir isteği tamamlamış (`served`), istek başlığını bekliyor (`idle`, ilk bayt gelince — kova beklemesinden önce — `false`), ≥ `evictIdleMs` boşta ve soket tamponunda okunmamış bayt yok (`available()==0`). Yeni bağlantı ilk isteği bitene kadar asla tahliye edilmez → T-138 canlı kilidi biter.
   - Yumuşak sınırda (8) tahliye edilebilir bağlantı yoksa yeni bağlantı **beklemeden** taşma olarak kabul edilir (sert sınır 8+4=12; bellek ≤ 12×2×64 KB).
   - Sert sınırda: en eski gerçekten boştaki bağlantıyı düşür; yoksa ≤ `admitWaitMs` bekle, sonra `503 Service Unavailable` + `Retry-After: 1` + `Connection: close` (kısa ömürlü reddetme iş parçacığı, istek başlığını okuyup yanıtlar). Gerekçe: webdavfs kaynağı (`webdav_network.c` `translate_status_to_error`) 503'ü yeniden denemiyor, `ENOENT`'e çeviriyor → 503 yalnız son çare; normal yol taşma. Mac'te ölçülerek doğrulanır.
3. Yazma zaman aşımı: `WriteWatchdog` (saf, saat enjekte edilebilir) + tek izleyici iş parçacığı (hiç yazım yokken süresiz bekler, yoklama yok). `ThrottledOutputStream` her ham soket yazımını `begin/end` ile işaretler; kova beklemesi işaret dışında kalır. `writeTimeoutMs` boyunca biten yazım yoksa soket kapatılır, `write_stalled` loglanır.
4. JVM testleri: 4 uzun GET sürerken 5. ve 6. küçük istek < 1 s; yeni (isteksiz) bağlantılar birbirini tahliye etmez, sert sınırda 503 ≤ ~admitWait; boştaki bağlantı ≥ evictIdleMs sonra tahliye edilir; okunmayan yanıt kısa `writeTimeoutMs` ile kapanır; `WriteWatchdog` birim testleri.
5. `tools/dav-repro`: `DavRepro.java` yeni yapılandırıcı + ortam değişkenleri (`MB_DAV_OVERFLOW`). Mac ölçümü (UI yok): run8 (readers 4×2 GB) ve run6 yerine UI'siz `ql` tetiği (qlmanage -t, Finder'ın küçük resim yolu) — önce (cc65a9f) / sonra.

## Handoff

**Commit:** `09a2530` (kod + testler + araç), plan `ba5933b`; dal `task/T-139-files-conn` (cc65a9f'den).

**Dosyalar:** `client-android/app/src/main/kotlin/dev/matebridge/client/files/{FilesConfig,DavServer,HttpIo}.kt`, yeni `WriteWatchdog.kt`; testler `DavServerTest.kt` (+5 test, 1 güncellendi), yeni `WriteWatchdogTest.kt` (3); `tools/dav-repro/DavRepro.java` (yeni yapılandırıcı, `MB_DAV_OVERFLOW`), `bulk.sh` (yalnız açıklama); bu kart.

### Ne yapıldı
- `MAX_CONNECTIONS` 4 → **8** (yumuşak sınır). Yeni `FilesConfig` alanları: `evictIdleMs` 1 000, `overflowConnections` 4, `admitWaitMs` 2 000, `writeTimeoutMs` 30 000.
- **Tahliye yalnız gerçekten boştakine:** `served` (≥1 istek tamamlandı) + `idle` (başlık bekliyor; ilk bayt soketten gelince, kova beklemesinden önce `false`) + ≥ `evictIdleMs` + soket `available()==0`. Yeni kabul edilmiş bağlantı ilk isteği bitene kadar asla düşürülmez → T-138 canlı kilidi kapandı.
- **Sınırda boşta yoksa bekleme yok, taşma:** yeni bağlantı hemen kabul edilir, sert sınır 8+4 = 12 (bellek ≤ 12×2×64 KB ≈ 1,5 MB). `conn_overflow` logu (≤ 1/s).
- **Sert sınırda:** gerçekten boştaki düşürülür; yoksa ≤ 2 s bekler, sonra `503` + `Retry-After: 1` + `Connection: close` (kısa ömürlü `mb-files-reject` iş parçacığı, başlığı okur, biraz gövde boşaltır; en fazla 2 eşzamanlı). `conn_rejected` logu.
- **Yazma zaman aşımı:** `WriteWatchdog` + tek `mb-files-watchdog` iş parçacığı (yazım yokken süresiz `wait`, yoklama yok). `ThrottledOutputStream` yalnız ham soket yazımını işaretler; kova beklemesi sayılmaz. 30 s ilerleme yoksa soket kapanır, `write_stalled` logu.

### Kart kriterinden sapma (gerekçeli): 503 yalnız son çare, normal yol taşma
Kart "≤ 2 s bekle, sonra 503 (webdavfs yeniden dener)" diyordu. **webdavfs 503'ü yeniden denemiyor:** `mount.tproj/webdav_network.c` `translate_status_to_error()` 5xx'te (507 hariç) `ENOENT` döndürüyor; `send_transaction` döngüsü yalnız `EAGAIN` (EPIPE/ConnectionLost, bir kez) ve 401/407'de tekrar ediyor. Yani 503 alan küçük kopya/stat "dosya yok" hatası alırdı. Bu yüzden 5. ve 6. istek 503 değil taşma yuvası alır (bekleme yok). 503 yalnız 12 bağlantı doluyken ve hiçbiri boşta değilken. webdavfs'in 5 istek iş parçacığı buna normalde ulaşamaz; sonsuz bekleme de artık yok. JVM testleri her iki yolu da kapsıyor. 503'ün Mac'teki etkisi bilerek ölçülmedi, çünkü sert sınırı doldurmak birimi takar (orkestratör uyarısı).

### JVM testleri (hepsi geçiyor, 3 tekrar kararlı)
- `smallRequestsAreAnsweredWhileFourLongDownloadsRun`: varsayılan sınırlar, 4 MB/s, 4×256 MB GET sürerken 5. ve 6. istek 200 ve < 1 s (eski kodda 5. sonsuza dek beklerdi).
- `beyondTheLimitBusyConnectionsGetOverflowSlotsAtOnce`: sınır 2, taşma 2. 2 uzun GET varken 2 yeni bağlantı beklemeden 200 alır.
- `freshConnectionsNeverEvictEachOtherAndTheHardLimitAnswers503`: isteksiz 2 bağlantı düşürülmez. 3. bağlantı taşma yuvası alır. 4. bağlantı ~600 ms sonra 503 + `Retry-After: 1` alır, ardından kapanır. İlk ikisi hâlâ çalışır.
- `keepAliveCarriesSeveralRequestsAndIdleConnectionsAreEvicted` (güncellendi): en uzun boşta olan bağlantı düşürülür, diğeri kalır.
- `aResponseNobodyReadsIsClosedAfterTheWriteTimeout` (500 ms) / `waitingOnTheRateCapIsNotAWriteStall` (100 KB/s, 300 ms zaman aşımı, ~650 ms kova beklemeleri, aktarım tamamlanır).
- `WriteWatchdogTest`: sahte saatle süre dolumu, ilerleyen yazım hiç dolmaz, iş parçacığı yalnız takılanı tetikler ve durur.

### Mac ölçümleri (JVM sunucu, 20 MB/s, gerçek webdavfs bağlama; 141 KB kopya; UI yok)
| Koşu | Kod | Küçük kopya (aşağı / yukarı) | Diğer |
|---|---|---|---|
| boşta | sonra | 115–122 ms | – |
| run8 (readers, 4×2 GB, vekil), T-138 | önce (sınır 4) | 660 ms, 1 117 ms, sonra **TAKILDI >30 s** | moov 8,4 s/ETIMEDOUT; 302 s `reqs=0`; umount busy |
| run8 tekrar (bu kart, kesildi) | önce (cc65a9f) | 664 ms; sonra 5 kopya **TAKILDI >30 s** | orkestratörün uyarısıyla durduruldu: takılı bağlama Mac'i yavaşlattı. Bağlama ve süreçler temizlendi |
| run8, readers dosyaları tutarken | **sonra** | 120 / 345, 248 / 353, 136 / 346 ms | moov (kuyruk) okumaları 30–153 ms; 8 bağlantı; 20 MB/s indirme sürerken; umount: dosyalar hâlâ açıktı (HOLD zamanlaması) → busy, normal |
| run8, dosyalar kapandıktan sonra | **sonra** | 113–139 ms (6 kopya) | 9 bağlantı; **plain umount OK** |
| run6 yerine `ql` (qlmanage -t, 4×2 GB) | **sonra** | 113–140 ms (6 kopya) | 12 bağlantı, 8 MB toplam; **plain umount OK** |

run6'nın Finder tetiği UI açtığı için kullanılmadı. Yerine UI'siz `qlmanage -t` tetiği kullanıldı (aynı QuickLook küçük resim yolu). Her koşu ≤ 75 s sınırlıydı. Sonunda test bağlaması, sunucu, okuyucular ve büyük dosyalar silindi (`mount` içinde webdav yok). Çalışan host'a, `/Volumes/MatePad`'e ve tablete dokunulmadı.

**check.sh:** ALL OK.

### Test edilmeyenler
- Gerçek tablet (Android soket `available()`, eşzamansız kapatmanın yazımı çözmesi). JVM'de doğrulandı, Android'de de aynı olmalı.
- Finder tetiği (UI yasağı). ≥5 büyük dosya (T-138'deki kalan risk; webdavfs sınırı, sunucu çözemez). 503'ün gerçek webdavfs etkisi.

### Tablette / Mac'te kontrol
1. İçinde ≥4 büyük video (≥1 GB) olan klasörü Finder'da aç. Hemen o klasörden Mac'e 141 KB'lık bir dosya kopyala, sonra Mac'ten klasöre bir dosya kopyala: ikisi de < 2 s. `adb logcat -s 'MB:*'` içinde `reqs=0` + `bytes_out≈20 MB/s` dakikalarca sürmemeli. `conn_overflow` görülebilir; bu normal.
2. Videolar kapanınca birimi Finder'dan çıkar: "kullanımda" hatası çıkmamalı.
3. Kopya ve önizleme sırasında görüntü akışı aynı akıcılıkta olmalı (toplam tavan değişmedi).
4. Logda `conn_rejected` ve `write_stalled` normal kullanımda görünmemeli. Görünürse kart açılmalı.

## Open questions

- Kalan risk (≥5 eşzamanlı büyük dosya; T-138 Handoff 3. madde) bu kartın kapsamı dışında, açık.
- Kart 503'ü ana yol olarak öngörüyordu; yukarıdaki gerekçeyle taşma ana yol, 503 son çare. Orkestratör onaylamalı.
