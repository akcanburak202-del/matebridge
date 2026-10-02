---
id: T-132
title: Mac — uykuya girerken oturumu BYE(HOST_SLEEP) ile kapat
status: done
phase: 4
owner: mac-host-dev
depends_on: [T-128]
decisions: []
files:
  - host-mac/Sources/MateBridgeHost/
  - host-mac/Sources/MateBridgeCore/
  - host-mac/Tests/
  - backlog/tasks/T-132-host-bye-host-sleep.md
---

## Amaç

Cihaz testi (NOTES 2026-10-02 ~14:45): T-128 ile `pmset sleepnow` artık gerçekten uyutuyor (`wake_display_suppressed`, pmset "Entering Sleep"). Ama oturum **açık kaldı**: TCP bağlantıları uykuda yaşadı, tabletin 500 ms PING'leri ve 0,5 s'de bir video yeniden bağlanma denemeleri Mac'i sürekli **DarkWake**'e soktu (`E_RX_IP_PACKET`, 14:42:19 / 14:43:07 / 14:43:55, her biri 45 s). Tablet oturumu canlı sandı → son karede donmuş görüntü, "Mac uyandırılıyor…" hiç görünmedi, kullanıcı uygulamadan çıkıp girmek zorunda kaldı.

Çözüm (PROTOCOL.md §4 `BYE` reason `6` HOST_SLEEP, fixture `bye_host_sleep`): host uykuya girerken oturumu kendisi kapatır.

## Kabul kriterleri

- [x] Protokol: `BYE` reason `6` HOST_SLEEP Swift tarafında tanımlı; `FixtureTests`'e `bye_host_sleep` eklenir (kodlama/çözme bayt bayt).
- [x] Sistem uykusu bildiriminde (`kIOMessageSystemWillSleep`; `CanSystemSleep` değil — uyku iptal edilebilir) aktif ya da kanıt bekleyen oturum varsa: release-all (mevcut BYE yolu), `BYE(HOST_SLEEP)` gönderilir, iki bağlantı kapatılır, ses durdurulur; bunlar `IOAllowPowerChange`'den **önce** ve sınırlı sürede (ör. en çok ~300 ms beklenir; gönderim bitmese de onay verilir — uyku geciktirilmez/engellenmez). PAIRING onayı bekleyen bağlantılar da kapatılır.
- [x] Sanal ekran: uykuda display grace beklemeden kaldırılabilir ya da mevcut grace ile bırakılır — hangisi daha güvenliyse seç ve Handoff'ta gerekçelendir (ekran uykuda oluşturulamıyor: T-040 notu).
- [x] Uyanınca (`did_wake` ya da yeni oturum) normal akış: tablet yeniden bağlanınca T-128'in `session_started` yolu ekranı tam uyandırır. Uyku sırasında gelen bağlantılar (karanlık uyanma) normal kabul edilir.
- [x] Log: `component=session ev=bye_sent reason=host_sleep` ve `ev=power` sıralaması görülebilir.
- [x] Saf mantık (ne zaman BYE gönderilir) testli. `./scripts/check.sh` geçiyor — **not:** Android tarafı `bye_host_sleep` fixture testi T-133 birleşene kadar kırmızı olabilir; yalnızca o test kırmızıysa kabul.

## Kapsam dışı

Cihaz testi (orkestratör). Host'u çalıştırma.

## Plan

1. **Core (saf):**
   - `ByeReason.hostSleep = 6` (`Messages.swift`); `FixtureTests` geçerli fixture listesine `bye_host_sleep` → `.bye(.hostSleep)`.
   - `ReleaseCause.hostSleep` (log adı `host_sleep`); test yardımcısı `allReleaseCauses`'a eklenir.
   - `SessionMachine.hostSleep()`: `shutdown()` ile aynı yol (`endAll`), ama `BYE(HOST_SLEEP)`, neden `.hostSleep`, bağlantı başına `ev=bye_sent reason=host_sleep`. Aktif oturum: release-all → BYE → kapat → video kapat → `sessionEnded`. Kanıt bekleyen / HELLO bekleyen / anahtar arayan bağlantılar: BYE + kapat. PAIRING onayı bekleyen: onay iptal + BYE + kapat. Açık kalmış (orphan) onay penceresi de kapanır; kanıtlanmamış video bağlantıları kapanır.
   - `Session/HostSleep.swift`: `HostSleep.endsSessions(_:)` (yalnızca `.willSleep`; `can_sleep` iptal edilebilir), `budgetUs = 300 ms`, `lingerUs(startUs:nowUs:)` (kalan bütçe − pay, alt sınır 0), `waitDeadlineUs`.
2. **Host (`SessionServer`):** kendi `SystemPowerObserver`'ı (ikinci `IORegisterForSystemPower` kaydı; `StreamCoordinator`'ınkine ve `main.swift`'e dokunmadan). İşleyici güç kuyruğunda, `IOAllowPowerChange`'den önce: `willSleep` → oturum kuyruğuna `hostSleep()` işi (bsd kapanış bekleme süresi kalan bütçeye kısaltılır), sonra semafor + `flushGroup` toplamda en çok 300 ms beklenir; bitmese de döner (uyku onaylanır). Log `component=session ev=host_sleep conns=… ` ve `ev=host_sleep_ack waited_ms=… flushed=…`. `start()` gözlemciyi kurar, `stop()` kapatır.
3. **Sanal ekran:** mevcut grace ile bırakılır (gerekçe Handoff'ta).
4. **Testler:** `SessionMachineTests` (hostSleep: aktif, kanıt bekleyen, PAIRING bekleyen, orphan, boş) + `HostSleepTests` (olay seçimi, bütçe hesabı) + fixture.

## Handoff

- **Commit:** `1459820` (uygulama), `ef3f507` (Codex inceleme düzeltmeleri), plan `d31d5e3`; dal `task/T-132-host-bye-host-sleep` (taban `main` 56ecb58).
- **İnceleme düzeltmeleri (`ef3f507`, Codex):**
  1. *(P1) Girdi oturum kuyruğuna bağlı değil:* yeni `MateBridgeHost/Session/HostSleepParticipants.swift`, süreç genelinde bir kayıt. `will_sleep`'te güç işleyicisi her katılımcıyı **hemen ve paralel** başlatır, oturum kuyruğunu beklemez. `InputController` (`start()`'ta kaydolur, adı `input`) kendi kuyruğunda `release(.hostSleep)` yapar. Bu, normal yoldaki `releaseInput` ile aynı gövdedir (`releaseOnQueue`) ve idempotenttir; boş bırakma yalnızca `debug` loglanır. Oturum kuyruğu takılsa da girdi uyku onayından önce bırakılır. Oturum kuyruğu sonra yine bırakır (zararsız).
  2. *(P2) Bekleyen (lingering) bağlantılar:* kapatılan her kontrol bağlantısı, tamamlanana kadar kilitli bir tabloda (`LingeringConnections`) kendi iptaliyle tutulur. Bu, uykudan önce kapanmış olanları da kapsar (ör. devralmadaki 2 s'lik bsd linger). Kesme noktasında (`HostSleep.cutDeadlineUs` = başlangıç + 250 ms) hepsi **güç kuyruğundan** iptal edilir; oturum kuyruğuna gerek yoktur. `nw` yoluna da zaman aşımı eklendi: son gönderim tamamlanmazsa linger süresi sonunda (normalde 2 s, uykuda kalan bütçe) `cancel`. `flushGroup.leave` artık `OnceFlag` ile tek seferlik.
  3. *(P2) Ses:* `SystemAudioTap` (`init`'te kaydolur, adı `audio`) kendi kuyruğunda `desired = nil`, ardından çalışan yakalamayı söker (`AudioDeviceStop` → … → tap yok edilir). Log: `audio_capture_stopped stream_id=… reason=host_sleep`. Akıştaki sonraki `stop` işlem yapmaz. Bekleme aynı bütçe içinde ve ack logunda `audio=done|pending` olarak görünür.
  - Sıra (tek son tarih, toplam ≤ 300 ms): katılımcılar başlar → oturum kuyruğu işi (en geç kesme noktasına kadar beklenir) → `flushGroup` (kesme noktasına kadar) → lingering olanlar kesilir → katılımcılar son tarihe kadar beklenir → ack.
  - Saf mantık: `HostSleep.cutDeadlineUs` / `remainingToCutUs`, `HostSleepProgress` (katılımcı durumu + log alanları), testli (`HostSleepCutAndProgressTests` 4).
- **`./scripts/check.sh`:** host-mac `swift build` + `swift test` OK (646 test; yeni: `HostSleepTests` 5 + 4, `SessionMachineTests` +7, `FixtureTests` `bye_host_sleep`). Tek kırmızı: Android `FixtureTest.everyFixtureFileHasATestCase` (`bye_host_sleep` için Kotlin vakası yok) — kartta beklendiği gibi T-133 birleşince yeşile döner. Diğer her şey OK.
- **Dokunulan dosyalar:**
  - `host-mac/Sources/MateBridgeCore/Messages.swift` (`ByeReason.hostSleep = 6`)
  - `host-mac/Sources/MateBridgeCore/Session/SessionMachine.swift` (`ReleaseCause.hostSleep`; `hostSleep()`; `shutdown()` ile ortak `endAll`)
  - `host-mac/Sources/MateBridgeCore/Input/ReleaseRecord.swift` (log adı `host_sleep`)
  - `host-mac/Sources/MateBridgeCore/Session/HostSleep.swift` (yeni, saf: `endsSessions`, 300 ms bütçe, linger/kalan süre hesabı)
  - `host-mac/Sources/MateBridgeHost/Session/SessionServer.swift` (kendi `SystemPowerObserver`'ı, `onPower`, kısaltılmış linger, lingering tablosu ve kesme, `nw` linger zaman aşımı)
  - `host-mac/Sources/MateBridgeHost/Session/HostSleepParticipants.swift` (yeni: uyku katılımcıları kaydı)
  - `host-mac/Sources/MateBridgeHost/Input/InputController.swift` (`input` katılımcısı, `releaseOnQueue`)
  - `host-mac/Sources/MateBridgeHost/Audio/SystemAudioTap.swift` (`audio` katılımcısı, `deinit`'te kayıt silme)
  - `host-mac/Tests/MateBridgeCoreTests/FixtureTests.swift`, `.../Input/InputTestSupport.swift`, `.../Session/SessionMachineTests.swift`, `.../Session/HostSleepTests.swift` (yeni)
- **Davranış:**
  - Yalnızca `kIOMessageSystemWillSleep` (`will_sleep`) oturumları bitirir; `can_sleep` hiçbir şey yapmaz (boşta uykusu `will_not_sleep` ile iptal edilebilir). `pmset sleepnow` / menü > Uyku yalnızca `will_sleep` gönderir.
  - `SessionServer` kendi `IORegisterForSystemPower` kaydını tutar (`start()`'ta kurulur, `stop()`'ta kapanır). `StreamCoordinator`'ın T-128 gözlemcisi ve `main.swift` değişmedi (kart `files:` dışında). İki kayıt bağımsızdır; IOKit uykudan önce ikisinin de onayını bekler. `StreamCoordinator`'ınki hemen onaylar.
  - Güç kuyruğunda, `IOAllowPowerChange`'den **önce**: oturum kuyruğuna `machine.hostSleep()` işi konur → aktif oturum: release-all (`ReleaseCause.hostSleep`) → `BYE(HOST_SLEEP)` → kontrol kapat → video kapat → `sessionEnded` (uygulama bunu `audio.sessionEnded()` + `coordinator.sessionEnded()`'e bağlıyor, yani ses durur, display-sleep assertion bırakılır). Kanıt bekleyen devralma, HELLO / anahtar bekleyen bağlantılar: BYE + kapat. PAIRING onayı bekleyen: onay penceresi iptal + BYE + kapat. Açık kalmış (orphan) onay penceresi kapanır, kanıtlanmamış video bağlantıları kapanır.
  - Bekleme toplamda en çok `HostSleep.budgetUs` = 300 ms (katılımcılar + oturum kuyruğu + `flushGroup`), sonra her koşulda döner ve uyku onaylanır. Bu sırada kapanan kontrol soketlerinin linger süresi (normalde 2 s) kesme noktasına kadar kısalır (kalan bütçe − 50 ms). Kesme noktasında hâlâ bekleyen her kontrol bağlantısı güç kuyruğundan iptal edilir. Böylece soketler, onaydan önce Mac uyanıkken kesin kapanır (dispatch zamanlayıcısı uykuda çalışmaz).
  - Uyku sırasında / sonrasında gelen yeni bağlantılar (karanlık uyanma, gerçek uyanma) normal kabul edilir. Durum makinesinde kapı yok, testli. Uyanınca ekranı T-128'in `session_started` yolu uyandırır (değişmedi).
  - **Log** (`component=session`): `ev=host_sleep control=N video=M wall_ms=…` → bağlantı başına `ev=bye_sent conn=… reason=host_sleep` (+ girdi tarafında release kaydı `host_sleep`) → `ev=host_sleep_ack waited_ms=… queue=ran|late flushed=true|false cut=N input=done|pending audio=done|pending` (bir şey eksikse `W`). Ses tarafında (`component=audio`) yakalama çalışıyorsa `audio_capture_stopped … reason=host_sleep`. T-128'in `ev=power state=will_sleep wall_ms=…` satırı (coordinator) ayrı gözlemciden gelir; ikisinin göreli sırası garanti değil, `wall_ms` ile eşlenir.
- **Sanal ekran — mevcut grace ile bırakıldı (gerekçe):** (1) Ekranı kaldırmak `StreamCoordinator`'ın asenkron olay döngüsünde, özel API (`CGVirtualDisplay`) bırakılarak olur. Bunu 300 ms bütçesine ve uyku geçişine sıkıştırmak sınırlanamaz ve riskli. (2) Grace sayacı (`DisplayLease`, `HostClock` = mach absolute time + uptime tabanlı 1 s tik) uykuda ilerlemez. Tablet uyanmadan sonra grace içinde yeniden bağlanırsa mevcut ekran yeniden kullanılır. Böylece NOTES 14:45'teki "uykuda ekran oluşmuyor" (`display_create_failed`, T-040) durumundan kaçınılır. Bağlanılmazsa ekran uyanmadan ~10 s sonra normal kaldırılır. (3) Oturum yokken capture kaybı yeniden kurulum ya da uyandırma tetiklemez (`onPipelineFailed` canlı oturum ister).
- **Test edilmeyenler / cihazda doğrulanacaklar (orkestratör):**
  - Host çalıştırılmadı, uyku denenmedi (talimat gereği).
  - Oturum açıkken `pmset sleepnow`: `host_sleep` → `bye_sent reason=host_sleep` → `host_sleep_ack waited_ms<300 flushed=true` sırası. `pmset -g log`'da Sleep olmalı; sonrasında `E_RX_IP_PACKET` karanlık uyanmaları **olmamalı** (T-133'lü istemciyle; eski istemci bilinmeyen BYE sebebinde yeniden bağlanmaya çalışabilir).
  - `waited_ms` gerçek değeri: tablet FIN'i hızlı dönerse ~onlarca ms beklenir. `flushed=false` görülürse bütçe/linger yeniden düşünülmeli.
  - Boşta uykusu (Mac ayarı ile): `can_sleep` sırasında oturum kapanmamalı, yalnızca `will_sleep`'te kapanmalı (zaten T-128'in ekran uykusu assertion'ı oturum varken boşta uykuyu önler; bu yol ancak oturum yokken ya da zorunlu uykuda görülür).
  - Uyanınca (WoL / klavye) tablet yeniden bağlanınca `session_started` → `power state=awake reason=session_started` → ekran uyanması; sanal ekranın grace içinde yeniden kullanıldığı (`display_created` yerine yeniden kullanım) ya da grace bittiyse yeniden oluşturulduğu.
  - Onay penceresi açıkken uyku: pencere kapanmalı.
- **Varsayımlar / açık sorular:**
  - İki `IORegisterForSystemPower` kaydı kullanıldı (kapsam `main.swift`'e ve gözlemciler arası bağlantıya girmesin diye). İstenirse ileride tek bir paylaşılan gözlemciye birleştirilebilir.
  - Oturum kuyruğu kesme noktasına kadar meşgulse (`queue=late`): girdi ve ses yine bırakılır (katılımcılar), bekleyen bağlantılar kesilir. Ama **canlı** kontrol/video bağlantısı (tablo oturum kuyruğuna ait) açık kalabilir ve BYE işi kuyruk boşalınca çalışır. Bu, uyku geçişinin içinde ya da uyanmadan sonra olabilir. Uyanmadan sonra çalışırsa o an açık olan oturumu bitirir. Pratikte oturum kuyruğu bu kadar meşgul kalmaz; logda `W host_sleep_ack queue=late` görünür.
  - Katılımcılar süreç genelindeki bir kayıtta tutuluyor (`HostSleepParticipants.shared`), çünkü bileşenler yalnızca `main.swift`'te birbirine bağlanıyor ve o dosya kapsam dışı. `main.swift` kapsama alınırsa açık bağlantıya (closure) çevrilebilir.
  - Ses katılımcısı, oturum kuyruğu geç kalırsa akış (streamer) "yakalama sürüyor" sanarken tap'i söker. Uyanmadan sonra geç gelen oturum sonu bunu düzeltir; yeni oturum `start` ile yeniden kurar.
  - `nw` yolunda iptal edilen bağlantının `.contentProcessed` tamamlanmasının çağrıldığı varsayıldı. Çağrılmasa da zaman aşımı kapanışı `flushGroup`'u bir kez bırakır.
