---
id: T-138
title: Dosyalar — Finder'ın video önizlemeleri tüm dosyayı indiriyor, küçük kopyalar "hazırlanıyor"da takılıyor
status: done
phase: 5
owner: android-client-dev
depends_on: [T-137]
decisions: [0015]
files:
  - client-android/app/src/
  - host-mac/Sources/MateBridgeHost/Files/
  - host-mac/Sources/MateBridgeCore/Files/
  - host-mac/Tests/
  - tools/dav-repro/
  - backlog/tasks/T-138-files-bulk-blocks-small.md
---

## Amaç

Cihaz (2026-10-02 ~18:20): bağlama artık 0,17 s (T-137 tamam). Kullanıcı **141 KB** bir dosya kopyalamaya çalıştı; Finder "kopyalamaya hazırlanıyor"da kaldı. Aynı anda tablet dakikalarca kesintisiz ~20 MB/s gönderiyordu (`reqs=0`, `bytes_out≈20 MB`, `throttled_ms≈3700/s`; ~4,4 GB). `lsof -p <webdavfs_agent>`: `/private/tmp/.webdavcache.*/webdav.*` içinde **2,7 GB** önbellek dosyası. Finder `showIconPreview = 1`. Yani Finder/QuickLook klasördeki videoların önizlemesi için webdavfs **tüm dosyayı** indiriyor (webdavfs açılan dosyayı bütün olarak önbelleğe alır), hattı ve sunucuyu dolduruyor; küçük kopya arkada bekliyor.

## Kabul kriterleri

- [ ] **Tekrar üretim** (`tools/dav-repro`, JVM sunucu + gerçek NetFS bağlama, çalışan host'a ve `/Volumes/MatePad`'e dokunmadan): birkaç büyük (ör. 1–3 GB, seyrek/sahte) `.mp4` içeren klasör + Finder simge görünümü/QuickLook (`qlmanage -t` ile tetiklenebilir) + aynı anda küçük dosya kopyası (`cp`). Küçük kopyanın ne kadar beklediği ve neyi beklediği (sunucu bağlantı sınırı 4? token bucket'ta toplu aktarımın arkasında kalma? webdavfs_agent içi sıra?) kanıtla gösterilir.
- [ ] **Kök nedene göre düzeltme** (öneriler, kanıta göre seç):
  - sunucuda küçük/meta istekler (PROPFIND, küçük GET/PUT, LOCK…) toplu aktarımın arkasında beklemesin: ayrı/öncelikli bant ya da token bucket'ta öncelik; bağlantı sınırında küçük istekler için ayrılmış yer;
  - webdavfs'in tüm dosya indirmesi (ör. önizleme) sınırlanabiliyorsa (Range davranışı, yanıt başlıkları) araştır ve kanıtla;
  - host tarafında, bağlanan birim için Finder önizlemesini kapatmak gibi kullanıcı ayarlarını değiştiren çözümler **yapılmaz** (kullanıcının genel Finder ayarına dokunma); gerekiyorsa Handoff'ta öneri olarak yaz.
- [ ] Hedef: arka planda büyük önizleme indirmesi sürerken 141 KB'lık kopya < 2 s'de biter; görüntü akışı etkilenmez (toplam tavan aynı kalır).
- [ ] Testler + `./scripts/check.sh` geçiyor. Handoff'ta öncesi/sonrası ölçüm.

## Plan

**Kapsam değişikliği (kullanıcı kararı, 2026-10-02):** yalnız inceleme. Uygulama koduna (`client-android/app/src`, `host-mac/Sources`) dokunulmaz; düzeltme yalnız kanıtla **önerilir**. Araç değişiklikleri `tools/dav-repro/` altında.

1. `tools/dav-repro/bulk.sh`: JVM DavServer (cihaz tavanı 20 MB/s) + gerçek NetFS bağlaması (geçici dizin, `/Volumes` değil); klasörde 1–6 adet büyük ama geçerli `.mp4` (sistem `.mov`'undan `avconvert`, `bigmovie.py` ile seyrek 64-bit `free` kutusuyla 1–2 GB; `moov` sonda, telefon kaydı gibi). Tetik: `readers.py` (UI'sız; küçük resimleyicinin erişim deseni: hepsini aynı anda aç, baş + son 64 KB oku, tut), `qlmanage -t`, ya da (yalnız `MB_BULK_ALLOW_UI=1`) Finder penceresi. Tetik sürerken 141 KB kopya Mac→birim ve birim→Mac, süreleri; `sample webdavfs_agent`, `jstack` sunucu, `lsof` ile dosyayı tutan süreçler; düz (zorlamasız) `umount`.
2. Değişkenler: sunucu bağlantı sınırı (`MB_DAV_MAXCONN`), vekil yok (`MB_DAV_DIRECT=1`), okumayı bırakan tünel modeli (`MB_DAV_PROXY_RESET=stall`), kök dizinde `.ql_disablethumbnails` (`MB_BULK_QLOFF=1`).
3. webdavfs kaynağı (apple-oss-distributions/webdavfs) ile davranışı açıkla; kök neden + öneriler + öncesi/sonrası sayılar Handoff'a.

## Handoff

**Commit:** `805c3ac` (araç + bulgular), dal `task/T-138-files-bulk` (1d0263c'den). Uygulama kodu **değişmedi**.

**Dosyalar:** `tools/dav-repro/bulk.sh` (yeni), `readers.py` (yeni), `bigmovie.py` (yeni), `threads.py` (yeni), `DavRepro.java` (ortam değişkenleri: `MB_DAV_RATE`, `MB_DAV_MAXCONN`, `MB_DAV_DIRECT`, `MB_DAV_PROXY_RESET`; vekil artık istemci bağlantıyı sıfırlayınca iki ucu da kapatıyor — eskisi yarım kapatıp sunucuyu yazmada asılı bırakıyordu), bu kart.

### Kök neden (kanıtlı)

İki katman üst üste:

1. **webdavfs bir dosya açılınca dosyanın TAMAMINI indirir** ve bunu yaparken ajanın **5 istek iş parçacığından** birini dosya kapanana / indirme bitene kadar tutar (kaynak: `webdavd.h` `WEBDAV_REQUEST_THREADS 5`; `requestqueue_enqueue_download` indirmeyi kuyruğun başına koyar, `network_finish_download` iş parçacığında döner; `filesystem_close` indirmeyi ancak son kapanışta durdurur). İndirilmemiş bir uzak konumu okumak (ör. sonda duran `moov`) için çekirdek bir kez bayt aralığı okuması (`WEBDAV_READ` → `Range: bytes=a-b`) dener, olmazsa **indirmenin o konuma gelmesini bekler** (`webdav_vnops.c`, `tried_bytes`).
2. **Bizim sunucu (MateBridge DavServer) en fazla 4 bağlantı kabul ediyor ve sınırda "boşta" bağlantıyı kapatıyor** (`DavServer.admit`). Finder klasörü açınca küçük resim uzantısı (`AudiovisualThumbnailExtension`) ve Finder videoları açıyor → her biri 2 GB'lık tam GET ile bir bağlantıyı dakikalarca tutuyor. 4 yuva dolunca:
   - hiçbir bağlantı boşta değilse kabul iş parçacığı `admit` içinde **sonsuza dek bekliyor**; yeni istek çekirdeğin dinleme kuyruğunda kalıyor, **işleyiciye hiç ulaşmıyor** (cihazdaki `reqs=0 bytes_in=0`, `bytes_out≈20 MB/s`, Finder "beklenmeyen hata" = webdavfs istek zaman aşımı);
   - bir yuva boştaysa iki istemci onu **karşılıklı tahliye ediyor**: yeni kabul edilmiş bağlantı başlığı okunana kadar `idle=true` sayılıyor, sonraki bağlantı onu kapatıyor, CFNetwork yeniden deniyor → **canlı kilit** (Finder tetiğiyle 2 318 / 4 196 bağlantı; her 2 s'de ~133 bağlantı patlaması).
   - Sonuç: uzak okumalar (moov) yapılamıyor → küçük resimleyici dosyanın tamamının inmesini bekliyor → dosyalar dakikalarca açık → **birim çıkarılamıyor** ("Resource busy"/"Finder kullanıyor") ve küçük kopya bekliyor/zaman aşımına düşüyor.

Token bucket kök neden değil: takılma anında jstack'te 4 iş parçacığı `bucket-sleep[get]` (kendi payını bekliyor), kabul iş parçacığı `admit-wait`; küçük istek kovaya hiç gelmiyor.

**Kim tetikliyor (lsof, Finder tetiği):** `AudiovisualThumbnailExtension` (video1, video3) ve `Finder` sürecinin kendisi (video4) `.mp4`'leri açık tutuyor. Finder ayrıca küçük dosyaları (`readme.txt`, `.bin`) tam GET ile okuyor (küçük, zararsız). `mdworker`/Spotlight görülmedi (root süreçler kök yetkisiz lsof'ta görünmez). Diğer türler (`.mov/.zip/.pdf/.apk`) UI yasağından sonra Finder ile denenemedi; webdavfs **hangi süreç hangi dosyayı açarsa açsın** tamamını indirir, yani tetik "büyük dosyayı açan her şey" (önizleme olan her tür).

### Ölçümler (Mac, JVM sunucu 20 MB/s, gerçek NetFS; 141 KB kopya)

| Koşu | Durum | Küçük kopya | Diğer |
|---|---|---|---|
| boşta (her koşu) | – | 114–247 ms | – |
| run5: Finder, 4×2 GB mp4, sınır 4 | **önce** | 117 ms, **17 620 ms**, 119 ms | 2 318 bağlantı; 200+ s `reqs=0` + 20 MB/s; umount "Resource busy" (tutan: AudiovisualThumbnailExtension, Finder) |
| run8: readers, 4×2 GB, sınır 4 (vekil) | **önce** | 660 ms, 1 117 ms, **TAKILDI >30 s** (aşağı ve yukarı) | moov okuması 8,4 s / ETIMEDOUT; 302 s `reqs=0`, 5,75 GB aktarım, 545 bağlantı; umount busy |
| run11: aynı, **vekil yok** | **önce** | **TAKILDI >20 s** | 336 s `reqs=0`, 5,05 GB; jstack: accept `admit-wait`, 4×`bucket-sleep[get]` → vekil yapaylığı değil |
| run6: Finder, 4×2 GB, **sınır 8** | **sonra (aday)** | 118–138 ms (6 kopya) | 19 bağlantı, toplam 15,8 MB; umount OK |
| run9: readers, 4×2 GB, **sınır 8** | **sonra (aday)** | 154–421 ms (6 kopya) | moov okumaları 52–110 ms; 8 bağlantı, fırtına yok |
| run10: readers, **6**×1 GB, sınır 8 | kalan risk | **TAKILDI** (6 kopya) | webdavfs'in 5 iş parçacığı da tam indirmede; açılışlar 90 s; 331 s durma — sunucu düzeltemez |
| run7: Finder, sınır 4, kökte `.ql_disablethumbnails` | öneri elendi | 118–138 ms | dosya bulundu ama videolar yine okundu (103 MB, 422 bağlantı) → işe yaramıyor |
| run12: sınır 8, tünel okumayı bırakır modeli | ikincil risk | 195–245 ms | dosyalar kapanınca 4 sunucu iş parçacığı `socket-write[get]`'te **kalıcı** asılı (yazma zaman aşımı yok) |

### Önerilen düzeltme (uygulanmadı; ayrı kart)

1. **(Ana) `DavServer` bağlantı yönetimi:** `MAX_CONNECTIONS` 4 → **8** (webdavfs'in 5 istek iş parçacığı + boşta havuz; bellek 8×2×64 KB ≈ 1 MB). Ve **tahliye kuralı:** yalnız gerçekten boşta olanı kapat — en az bir isteği bitmiş, `readHead`'de ≥ ~1 s bekleyen ve okunmamış baytı olmayan (`available()==0`) bağlantı; yeni kabul edilmiş bağlantı ilk isteği bitene kadar tahliye edilemez. Hiçbiri yoksa beklemek yerine kısa bir taşma payı (ör. +2) düşünülebilir. Regresyon testi: 4 uzun GET sürerken 5. ve 6. bağlantının isteği < 1 s yanıtlanmalı; yeni kabul edilmiş bağlantı tahliye edilmemeli. Ölçüm: run6/run9 (sınır 8) → küçük kopya < 0,5 s, birim çıkarılabiliyor.
2. **(İkincil) yazma durma zaman aşımı:** yanıt gövdesi yazımı N s (ör. 30 s, `READ_TIMEOUT_MS` gibi) hiç ilerlemezse bağlantıyı kapat; okumayı bırakan bir tünel yuvayı kalıcı tutmasın (run12).
3. **(Kalan risk, webdavfs sınırı)** aynı anda ≥5 büyük dosya açılırsa (Finder simge görünümünde ≥5 büyük video görünen klasör) webdavfs'in kendisi ~dakikalarca durur; sunucu bunu çözemez. Seçenekler (doğrulanmadı): kullanıcıya öneri — MatePad penceresinde Cmd-J → "Simge önizlemesini göster" kapalı (yalnız o klasör/pencere; genel ayara dokunulmaz); ya da sunucunun birim köküne Finder görünüm seçenekli bir `.DS_Store` sunması (MetaStore) — ayrıca araştırılmalı. `.ql_disablethumbnails` işe yaramıyor (run7).

### Araç

`tools/dav-repro/bulk.sh [port]` (varsayılan 47812; 47010 reddedilir). Örnek: `MB_BULK_FILES=4 MB_BULK_WAIT=4 MB_BULK_LIMIT=30 tools/dav-repro/bulk.sh` (önce), `MB_DAV_MAXCONN=8 …` (aday). Varsayılan tetik `reads` (UI yok). `finder` tetiği ekranda pencere açar, yalnız `MB_BULK_ALLOW_UI=1` ile. Takılmış bağlamada temizlik birkaç dakika sürebilir (sunucu önce öldürülür, sonra `umount`/`umount -f`). Geçici dizin, test bağlaması ve webdavfs önbelleği her koşudan sonra silindi; çalışan host'a ve `/Volumes/MatePad`'e dokunulmadı (koşular sırasında o birim orkestratör tarafından zaten ayrılmıştı).

**Not (UI):** 2. ile 7. koşular Finder'da geçici pencere açtı (birim ayrılınca kapandı); orkestratörün uyarısından sonra Finder/`open` kullanılmadı.

**check.sh:** ALL OK (uygulama kodu değişmedi).

### Tablette / Mac'te kontrol (düzeltme kartı uygulandıktan sonra)
1. İçinde ≥4 büyük video (≥1 GB) olan klasörü Finder'da aç; aynı anda o klasörden Mac'e 141 KB'lık bir dosya kopyala: < 2 s bitmeli. Tablet logunda `reqs=0` + `bytes_out≈20 MB/s` dakikalarca sürmemeli.
2. Birkaç saniye sonra birimi Finder'dan çıkar: "kullanımda" hatası olmamalı.
3. Görüntü akışı aynı akıcılıkta (toplam tavan değişmiyor).
4. ≥5 büyük video olan klasörde aynı test (kalan risk): takılma olursa Handoff 3. madde.

## Open questions

- Kalan risk (≥5 eşzamanlı büyük dosya açılışı) için kullanıcıya önizleme ayarı önerisi mi, yoksa sunucu tarafında `.DS_Store` ile birim-özel görünüm seçeneği mi araştırılsın? (UI gerektirir; kullanıcı ekranında Finder açmadan doğrulanamaz.)
- Kartın "düzeltme + testler" kabul kriterleri bu kartta karşılanmadı (kullanıcı kararıyla yalnız inceleme); düzeltme için yeni kart gerekir.
