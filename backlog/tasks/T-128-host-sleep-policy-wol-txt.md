---
id: T-128
title: Mac — kasıtlı uykuya saygı, oturumda ekran uykusunu önle, Bonjour TXT `wol` (Wake-on-LAN adresleri)
status: done
phase: 4
owner: mac-host-dev
depends_on: [T-081]
decisions: []
files:
  - host-mac/Sources/MateBridgeHost/
  - host-mac/Sources/MateBridgeCore/
  - host-mac/Tests/
  - backlog/tasks/T-128-host-sleep-policy-wol-txt.md
---

## Amaç

Ölçüm (NOTES 2026-10-02 ~13:45): tablet oturumu açıkken `pmset sleepnow` → ekran kapandı → SCStream -3815 → T-081 `wake_display` (`IOPMAssertionDeclareUserActivity`) → **sistem uykusu iptal oldu** (pmset log'da Sleep girdisi yok), Mac kilitlendi, görüntü 1,2 s'de geri geldi. Yani MateBridge kasıtlı uykuyu engelliyor.

**Kullanıcı kararı (2026-10-02):** Mac uzun süre kullanılmayınca uyusun (enerji tasarrufu; dakika ayarını kullanıcı macOS'ta kendisi yapar). Akış: tablet kendi ekran zaman aşımıyla kapanır → oturum BYE ile biter → Mac boşta → macOS ayarına göre ekran uykusu + sistem uykusu → kullanıcı dönünce tablet Wake-on-LAN magic packet ile Mac'i uyandırır (T-129) → otomatik yeniden bağlanma → kilit ekranında şifre tablet klavyesiyle.

Bu kart host tarafı. Protokol: `docs/PROTOCOL.md` §3 madde 1, TXT `wol` (orkestratör yazdı; bu kart yalnızca uygular).

## Kabul kriterleri

- [ ] **Kasıtlı / sistem uykusu engellenmez.** Sistem uykuya giderken (IOKit `IORegisterForSystemPower`: `kIOMessageCanSystemSleep` / `kIOMessageSystemWillSleep`; ve/veya `NSWorkspace.willSleepNotification`) T-081 uyandırması **bastırılır**; `kIOMessageSystemHasPoweredOn` / `didWakeNotification` ile yeniden açılır. Sıralama sorunu: `pmset sleepnow`'da ekran kapanması / -3815 uyku bildiriminden **önce** gelebilir. Bu yüzden `capture_source_lost` uyandırması kısa bir süre (ör. ~1,5 s, sabit olarak tanımla) ertelenir; bu pencerede uyku bildirimi gelirse uyandırma yapılmaz. `display_create_nil` yeniden denemeleri de uyku süresince uyandırma yapmaz. `kIOMessageCanSystemSleep`'e `IOAllowPowerChange` ile hemen izin verilir (uykuyu geciktirme yok).
- [ ] Log: `component=net ev=power state=will_sleep|did_wake|can_sleep` (değişimde) ve uyandırma bastırılınca `ev=wake_display_suppressed reason=system_sleep` (bölüm başına bir kez). Cihaz testinde sıralamayı görebilmek için zamanlar host saatinde.
- [ ] **Oturum açıkken boşta ekran uykusu yok.** Kabul edilmiş (PAIRED) oturum boyunca `IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleDisplaySleep)` tutulur, oturum bitince (BYE, devralma, kopma, kapanış) bırakılır. Gerekçe: kullanıcı ekran uykusunu açınca oturum ortasında ekran kararıp kilit ekranı çıkmasın; boşta kalma süresini tablettin kendi ekran zaman aşımı yönetir. (T-081'deki "PreventUserIdleDisplaySleep eklenmez" maddesinin yerine geçer — kullanıcı kararı.) Display grace süresinde (oturum yok) assertion yok. Mevcut `.userInitiated` activity (sistem boşta uykusunu önler) davranışı oturumla sınırlı kalır; oturum bitince bırakıldığını doğrula (bırakılmıyorsa düzelt).
- [ ] **TXT `wol`.** `BonjourAdvertiser` TXT'ye `wol=` ekler (PROTOCOL.md formatı: küçük harf `aa:bb:cc:dd:ee:ff`, virgülle, en çok 4; `en*`, `IFF_UP`, IPv4 adresi olan arayüzler; `getifaddrs` AF_LINK). Uygun arayüz yoksa anahtar hiç yazılmaz. Ağ arayüzleri değişince (ör. `SCDynamicStore` ya da `NWPathMonitor` değişimi) TXT yeniden yayınlanır; değer aynıysa tekrar yayın yok. Log: `component=session ev=bonjour_txt wol_count=N` (değişimde; MAC adresleri loglanmaz).
- [ ] Saf mantık testli: uyku/uyandırma politika durum makinesi (erteleme penceresi, bastırma, uyanınca yeniden açılma), TXT `wol` değer üretimi (biçim, sıralama kararlı, 4 sınırı, filtre). IOKit / dns_sd / getifaddrs çağrıları ince sarmalayıcılarda.
- [ ] `./scripts/check.sh` geçiyor.

## Kapsam dışı

- Gerçek `pmset sleepnow` / ekran uykusu cihaz testi (orkestratör kullanıcıyla yapar; Mac uyuyunca ajan devam edemez). Host'u çalıştırma, bundle etme.
- macOS enerji ayarlarını değiştirme.

## Plan

1. **Saf mantık (Core):**
   - `MateBridgeCore/Video/SleepWakeGate.swift`: `PowerEvent` (`can_sleep`, `will_sleep`, `will_not_sleep`, `did_wake`) + IOKit mesaj kodu sınıflandırması (`0xE0000270/280/290/300`); `SleepWakeGate` durum makinesi: `power(_:now:)` (uyku → bastır, bekleyen ertelemeyi düşür; uyanma → yeniden aç; log yalnızca durum değişince), `request(_:now:)` (`.suppressed(log:)` uykuda, bölüm başına bir log; `capture_source_lost` → `.deferred(deadline)` sabit `captureLossDeferUs = 1,5 s`; bekleyen erteleme varken `.pending`; `display_create_nil` uyanıkken `.wakeNow`), `due(now:)` (süre dolunca bekleyen nedeni verir), `cancelPending()` (ekran geri geldi / oturum bitti).
   - `MateBridgeCore/Session/WakeOnLanTxt.swift`: `getifaddrs` girdilerini (ad, `IFF_UP`, AF_LINK adresi / AF_INET) arayüz başına birleştirme, `en<sayı>` + up + IPv4 + geçerli 6 bayt unicast MAC filtresi, `en` numarasına göre kararlı sıra, tekrarları atma, en çok 4, küçük harf `aa:bb:…` virgülle; uygun yoksa `nil`. `sockaddr_dl` bayt ayrıştırması. TXT girdileri `v=1` (+ `wol=`).
   - `BonjourAdvertiser.updateTXT(_:)` (`DNSServiceUpdateRecord`, birincil TXT).
2. **Host sarmalayıcılar (`MateBridgeHost`):**
   - `Session/SystemPower.swift`: `SystemPowerObserver` (`IORegisterForSystemPower`, kendi dispatch kuyruğu; `CanSystemSleep`/`SystemWillSleep`'e olayı işledikten hemen sonra `IOAllowPowerChange`), `DisplaySleepAssertion` (`IOPMAssertionCreateWithName("PreventUserIdleDisplaySleep")`, tut/bırak idempotent).
   - `Session/NetworkInterfaces.swift`: `getifaddrs` → Core girdileri.
3. **`StreamCoordinator`:** kapı kilitli kutuda (IOKit kuyruğu + olay döngüsü). `start()` gözlemciyi kurar; güç olayı → `ev=power state=… wall_ms=…` (değişimde), bekleyen erteleme düşerse `ev=wake_display_suppressed reason=system_sleep`. `wakeDisplayIfNeeded` önce kapıya sorar; erteleme için kesin zamanlı bir görev `.deferredWakeDue` olayı postalar; süre dolunca T-081 politikası (oran sınırı) ile uyandırır. `display_created` / oturum sonu / kapanışta bekleyen erteleme iptal. Oturum başlayınca `PreventUserIdleDisplaySleep` alınır, oturum sonu / kapanışta bırakılır (`ev=display_sleep_assertion state=held|released`). `.userInitiated` activity (`InputController`) zaten `sessionEnded`/`shutdown`'da bırakılıyor — doğrulandı, değişiklik yok.
4. **`SessionServer`:** başlangıçta ve `NWPathMonitor` güncellemesinde `wol` yeniden hesaplanır; değişince `ev=bonjour_txt wol_count=N` loglanır ve TXT güncellenir (bsd: `updateTXT`, başarısızsa yeniden kayıt; nw: `listener.service` yeniden atanır). `stop()` izleyiciyi kapatır.
5. **Testler:** `Tests/MateBridgeCoreTests/Video/SleepWakeGateTests.swift`, `Tests/MateBridgeCoreTests/Session/WakeOnLanTxtTests.swift` (+ yerel Bonjour TXT güncelleme testi).

## Handoff

- **Commit:** `ae5b81e` (uygulama), `797af79` (inceleme düzeltmeleri), plan `380c408`; dal `task/T-128-host-sleep-policy` (taban `main` 8c9c746). `./scripts/check.sh` → ALL OK (host-mac 332 test; `SleepWakeGateTests` 19, `WakeOnLanTxtTests` 12).
- **İnceleme düzeltmeleri (`797af79`, Codex + reviewer):**
  1. *Uyandırma/uyku yarışı:* kapı kararı (`request`/`due`), T-081 oran sınırı ve `IOPMAssertionDeclareUserActivity` artık aynı `gateLock` altında (`wakeDisplayLocked`); güç işleyicisi `IOAllowPowerChange`'den önce aynı kilidi alıyor. Yani `will_sleep` karar ile çağrı arasına giremez; kilit altında `sleeping` bir kez daha denetlenir. Loglar kilit dışında.
  2. *Dark wake (WoL):* `SleepWakeGate.sessionStarted()` kapıyı açar ve bekleyeni temizler; `onSessionStarted`'da çağrılır, kapı kapalıydıysa `ev=power state=awake reason=session_started wall_ms=…` loglanır. `will_sleep` geldiğinde zaten canlı olan oturum etkilenmez (kapı yalnızca yeni oturumla açılır). Testli.
  3. *Bayat erteleme:* `request()` son tarihini `stalePendingUs` (1 s) aşmış bekleyeni bayat sayar, atar ve yeni isteği normal işler. Ayrıca 2. madde oturum başında temizler. Testli.
  4. *`pipeline_retry` zamanlaması:* bekleyen erteleme varsa yeniden deneme önce son tarihe kadar bekler, uyandırmayı kendisi çalıştırır (olay döngüsü bu sırada meşgul olduğu için `.deferredWakeDue` yeniden denemeden sonra işlenirdi), sonra ekranların açılması için 500 ms (`retryAfterDeferredWakeUs`) bekler. En az 1 s (`pipelineRetryUs`, artık hatadan itibaren ölçülüyor). Eski yorum düzeltildi. Not: önerilen ~200 ms yerine 500 ms seçildi (NOTES'ta ekranın dönüşü ~1,2 s); cihazda kısaltılabilir.
  5. *Oturum sonu taşmada kaybolmasın:* `.sessionEnded` artık `forced` postalanıyor (oturum başına bir tane, sınırlı) ve taşma temizliğinde `.shutdown` gibi yeniden kuyruğa konuyor. Düşen bir `.sessionStarted` için `onOverflow` oturumu bitirir, o da yeni bir `.sessionEnded` üretir. Host hedefinin test hedefi olmadığı için birim testi yok; mantık `BoundedMailbox`'ın mevcut `forced` davranışına dayanıyor.
  6. *`wol` uzlaştırma:* `SessionServer`'ın 100 ms'lik tikinde 60 s'de bir (`wolReconcileTicks = 600`) `getifaddrs` yeniden okunur; yalnızca değer değişince yayınlanır. `NWPathMonitor` da duruyor.
- **Dokunulan dosyalar:**
  - `host-mac/Sources/MateBridgeCore/Video/SleepWakeGate.swift` (yeni, saf: `PowerEvent` + IOKit mesaj kodları, erteleme/bastırma durum makinesi)
  - `host-mac/Sources/MateBridgeCore/Session/WakeOnLanTxt.swift` (yeni, saf: `wol` değeri, `sockaddr_dl` ayrıştırma, TXT girdileri)
  - `host-mac/Sources/MateBridgeCore/Session/BonjourAdvertiser.swift` (`updateTXT`, `DNSServiceUpdateRecord`)
  - `host-mac/Sources/MateBridgeHost/Session/SystemPower.swift` (yeni: `SystemPowerObserver` = `IORegisterForSystemPower`; `DisplaySleepAssertion` = `PreventUserIdleDisplaySleep`)
  - `host-mac/Sources/MateBridgeHost/Session/NetworkInterfaces.swift` (yeni: `getifaddrs` sarmalayıcı)
  - `host-mac/Sources/MateBridgeHost/Session/StreamCoordinator.swift` (kapı + gözlemci + assertion bağlama)
  - `host-mac/Sources/MateBridgeHost/Session/SessionServer.swift` (TXT `wol`, `NWPathMonitor`, yeniden yayın)
  - `host-mac/Tests/MateBridgeCoreTests/Video/SleepWakeGateTests.swift`, `host-mac/Tests/MateBridgeCoreTests/Session/WakeOnLanTxtTests.swift` (yeni; yerel Bonjour TXT güncelleme + resolve testi dahil)
- **Davranış / varsayımlar:**
  - Uyku: `can_sleep` ya da `will_sleep` → kapı kapanır (bekleyen erteleme düşer), `will_not_sleep` ya da `did_wake` → açılır. `CanSystemSleep` ve `SystemWillSleep`'e olay işlendikten hemen sonra `IOAllowPowerChange` (geciktirme/veto yok). Gözlemci kendi kuyruğunda (`dev.matebridge.power`), `StreamCoordinator.start()`'ta kurulur, `shutdown()`'da kapanır; kurulamazsa `ev=power_observer_failed` (T-081 davranışı ertelemeyle sürer).
  - `capture_source_lost` → `ev=wake_display_deferred reason=… defer_ms=1500`, 1,5 s (`SleepWakeGate.captureLossDeferUs`) sonra T-081 oran sınırıyla uyandırır. Pencere içindeki ek kayıplar (ör. 1 s'deki `pipeline_retry` → `display_create_nil`) bekleyene katılır, erken uyandırmaz. Ekran geri gelirse (`display_created`), oturum biterse ya da kapanışta erteleme iptal. `display_create_nil` uyanıkken ve bekleyen yokken T-081'deki gibi hemen uyandırır.
  - Log (`component=net`): `ev=power state=can_sleep|will_sleep|will_not_sleep|did_wake wall_ms=<unix ms>` (yalnızca değişimde; `wall_ms` `pmset -g log` ile eşleştirmek için, satırın kendi zaman damgası uptime ms), `ev=wake_display_suppressed reason=system_sleep lost=<neden>` (uyku bölümü başına bir kez; bekleyen erteleme düşünce ya da uykudayken gelen ilk kayıpta).
  - Ekran uykusu: kabul edilmiş oturumda (`onSessionStarted`, geçerli ayarlarla) `PreventUserIdleDisplaySleep` alınır; `onSessionEnded` (BYE, devralma, kopma) ve `onShutdown`/`shutdown()`'da bırakılır. Grace süresinde yok. Log: `ev=display_sleep_assertion state=held|released`, hata `ev=display_sleep_assertion_failed iokit=0x…`. Zorunlu uyku (`pmset sleepnow`, menü > Uyku) bu assertion'dan etkilenmez.
  - `.userInitiated` activity (`InputController`): `sessionEnded` ve `shutdown`'da `endActivity()` zaten çağrılıyor, `sessionStarted` öncekini bitirip yeniden başlatıyor — doğrulandı, değişiklik yok (sunucu her oturum sonunda `handlers.sessionEnded` çağırıyor; uygulama bunu `input.sessionEnded()`'e bağlıyor).
  - TXT `wol`: `en<sayı>`, `IFF_UP`, IPv4'lü, 6 bayt unicast, sıfır olmayan MAC; `en` numarasına göre sıra, tekrarlar atılır, en çok 4; yoksa anahtar yok. Başlangıçta ve her `NWPathMonitor` güncellemesinde yeniden hesaplanır; yalnızca değer değişince `component=session ev=bonjour_txt wol_count=N` loglanır ve yeniden yayınlanır (bsd: `DNSServiceUpdateRecord`, hata olursa `ev=bonjour_txt_update_failed` + yeniden kayıt; nw: `listener.service` yeniden atanır). MAC adresleri loglanmaz. Bu Mac'te `getifaddrs` ile 1 adres çıktı (scratch kontrolü; adres yazdırılmadı).
- **Test edilmeyenler / cihazda doğrulanacaklar (orkestratör + kullanıcı):**
  - Host çalıştırılmadı, bundle edilmedi, uyku denenmedi (talimat gereği).
  - Oturum açıkken `pmset sleepnow`: log sırası `pipeline_failed … -3815` → `wake_display_deferred` → `power state=will_sleep` (1,5 s içinde) → `wake_display_suppressed`; `pmset -g log`'da Sleep girdisi **olmalı**. Uyku bildirimi 1,5 s'den geç gelirse uyandırma yine uykuyu iptal eder — o zaman `wall_ms`/mono zamanlarından gerçek gecikme okunup sabit büyütülmeli.
  - Oturum açıkken `pmset displaysleepnow` (ya da ekran uykusu kısayolu): T-081 uyandırması artık ~1,5 s gecikmeli (`wake_display_deferred` → `wake_display`); görüntü ~2,5 s'de dönmeli.
  - Oturum açıkken kullanıcının ekran uykusu süresi dolunca ekran **kararmamalı** (`pmset -g assertions`'da "MateBridge: tablet session active" / PreventUserIdleDisplaySleep görünmeli); oturum bitince (tablet arka plan/BYE) kaybolmalı ve Mac normal enerji ayarına göre uyumalı.
  - Uyanınca (`did_wake`) yeniden bağlanma ve `ev=power state=did_wake` logu.
  - Bonjour: `dns-sd -B _matebridge._tcp` / `dns-sd -L <ad> _matebridge._tcp` ile TXT'de `v=1 wol=…` görünmeli; Wi-Fi'yi kapatıp açınca `ev=bonjour_txt wol_count=…` ve TXT'nin güncellendiği. `nw` kontrol soketiyle (`MATEBRIDGE_CONTROL_SOCKET=nw`) çalışan bir `NWListener`'da `service` yeniden atanınca TXT'nin güncellendiği doğrulanmadı (varsayılan `bsd` yolu yerel testle doğrulandı).
  - `NWPathMonitor` ikincil bir arayüzün yalnızca IPv4 alması gibi her değişimde tetiklenmeyebilir; bu durumda TXT en geç 60 s içinde periyodik okuma ile güncellenir.
  - Dark wake: WoL ile uyanan Mac'e tablet bağlanınca `ev=power state=awake reason=session_started` ardından (ekran kapalıysa) `wake_display` ve tam uyanma görülmeli (T-129 ile birlikte).
  - `pmset displaysleepnow` sırası artık: `pipeline_failed … -3815` → `wake_display_deferred` → ~1,5 s `wake_display` → ~0,5 s sonra `pipeline_retry` → `display_created`.
- **Açık sorular:**
  - Wake-on-LAN'ın gerçekten çalışması macOS ayarına bağlı ("Ağ erişimi için uyan" / `pmset -g` `womp 1`); bu kart ayarı değiştirmez. Wi-Fi'de magic packet ile uyanma donanım/macOS sürümüne göre desteklenmeyebilir — T-129 cihaz testinde görülecek.
  - Mac kilit ekranındayken (oturum yok) assertion tutulmaz; oturum açılınca tutulur. Kilit ekranında oturum açık ve kullanıcı boşta kalırsa ekran kararmaz — kullanıcı kararıyla tutarlı, ama NOTES'a yazılmalı.
